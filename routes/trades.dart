import 'dart:async';
import 'dart:math';

import 'package:dart_frog/dart_frog.dart';

import '../services/deriv_service.dart';
import '../services/market_analysis_service.dart';

/// ================= GLOBAL BOT STATE =================
final Map<String, ActiveTrade> _activeTrades = {};
final Map<String, StreamSubscription> _subscriptions = {};
final Set<String> _processedSignals = {};

bool AUTO_TRADING_ENABLED = true;
double MIN_CONFIDENCE = 0.72;
int MAX_TRADES = 5;
/// ================= DAILY PROTECTION =================
double DAILY_PROFIT_TARGET_PERCENT = 10;
double DAILY_LOSS_LIMIT_PERCENT = 5;

double DAY_START_BALANCE = 0;
DateTime? LAST_RESET_DAY;

/// ================= TRAILING STOP =================
double TRAILING_TRIGGER_RR = 1.5;
double TRAILING_STEP_RR = 0.5;

/// ================= PARTIAL TP =================
bool ENABLE_PARTIAL_TP = true;
double PARTIAL_TP_RR = 1.0;

/// ================= EQUITY PROTECTION =================
double START_BALANCE = 0;
double CURRENT_BALANCE = 0;
double MAX_DRAWDOWN_PERCENT = 25;
int MAX_LOSS_STREAK = 3;
int lossStreak = 0;

bool KILL_SWITCH = false;

/// ================= ACTIVE TRADE =================
class ActiveTrade {
  final String contractId;
  final String pair;
  final bool buy;
  final double entry;
  double sl;
  double tp;
  double current;

  bool breakeven = false;
  bool closed = false;

  ActiveTrade({
    required this.contractId,
    required this.pair,
    required this.buy,
    required this.entry,
    required this.sl,
    required this.tp,
    this.current = 0,
  });
}

/// ================= ENTRY POINT =================
Future<Response> onRequest(RequestContext context) async {

  // ================= GET ACTIVE TRADES =================

  if (context.request.method == HttpMethod.get) {
    return Response.json(
      body: {
        "success": true,
        "count": _activeTrades.length,
        "trades": _activeTrades.values.map((t) {
          return {
            "contractId": t.contractId,
            "pair": t.pair,
            "buy": t.buy,
            "entry": t.entry,
            "sl": t.sl,
            "tp": t.tp,
            "current": t.current,
            "breakeven": t.breakeven,
            "closed": t.closed,
          };
        }).toList(),
      },
    );
  }

  // ================= NEW SIGNAL =================

  if (context.request.method == HttpMethod.post) {
    final body = await context.request.json();
    return _handleSignal(body);
  }

  return Response(statusCode: 405);
}

/// ================= BALANCE =================
Future<double> _getBalance() async {
  final deriv = DerivService.instance;

  if (!deriv.isConnected) {
    await deriv.connect();
  }

  return deriv.getBalance();
}

/// ================= EQUITY CHECK =================
void _checkEquityProtection() {
  if (START_BALANCE == 0) return;

  final drawdown =
      ((START_BALANCE - CURRENT_BALANCE) / START_BALANCE) * 100;

  if (drawdown >= MAX_DRAWDOWN_PERCENT) {
    KILL_SWITCH = true;
    AUTO_TRADING_ENABLED = false;
    print("🚨 EQUITY DRAWDOWN HIT: $drawdown% BOT STOPPED");
  }
}
void _checkDailyLimits() {
  final now = DateTime.now();

  if (LAST_RESET_DAY == null ||
      LAST_RESET_DAY!.day != now.day ||
      LAST_RESET_DAY!.month != now.month ||
      LAST_RESET_DAY!.year != now.year) {
    LAST_RESET_DAY = now;
    DAY_START_BALANCE = CURRENT_BALANCE;
  }

  if (DAY_START_BALANCE <= 0) return;

  final pnlPercent =
      ((CURRENT_BALANCE - DAY_START_BALANCE) /
              DAY_START_BALANCE) *
          100;

  if (pnlPercent >= DAILY_PROFIT_TARGET_PERCENT) {
    AUTO_TRADING_ENABLED = false;
    KILL_SWITCH = true;

    print(
      "🎯 DAILY PROFIT TARGET REACHED: $pnlPercent%",
    );
  }

  if (pnlPercent <= -DAILY_LOSS_LIMIT_PERCENT) {
    AUTO_TRADING_ENABLED = false;
    KILL_SWITCH = true;

    print(
      "🛑 DAILY LOSS LIMIT REACHED: $pnlPercent%",
    );
  }
}
/// ================= SIGNAL HANDLER =================
Future<Response> _handleSignal(Map<String, dynamic> json) async {
  try {
    // ================= BOT STATE CHECK =================
    if (KILL_SWITCH || !AUTO_TRADING_ENABLED) {
      return Response.json(body: {"status": "BOT DISABLED"});
    }

    // ================= VALIDATION =================
    if (json['type'] != 'signal') {
      return Response.json(
        statusCode: 400,
        body: {"error": "Invalid payload"},
      );
    }

    // ================= EXTRACT SIGNAL =================
    final symbol = json['symbol']?.toString() ?? '';
    final direction = json['direction']?.toString() ?? '';
    final confidence = (json['confidence'] as num?)?.toDouble() ?? 0.0;
    final timestamp = json['timestamp']?.toString() ?? '';

    final signalId = "${symbol}_$timestamp";

    // ================= DUPLICATE PROTECTION =================
    if (_processedSignals.contains(signalId)) {
      return Response.json(body: {"status": "duplicate ignored"});
    }
    _processedSignals.add(signalId);

    // ================= LOSS PROTECTION =================
    if (lossStreak >= MAX_LOSS_STREAK) {
      KILL_SWITCH = true;
      return Response.json(body: {"status": "LOSS STREAK STOPPED"});
    }

    // ================= CONFIDENCE FILTER =================
    if (confidence < MIN_CONFIDENCE) {
      return Response.json(body: {"status": "low confidence rejected"});
    }

    // ================= MAX TRADE LIMIT =================
    if (_activeTrades.length >= MAX_TRADES) {
      return Response.json(body: {"status": "max trades reached"});
    }

    // ================= BALANCE UPDATE =================
    CURRENT_BALANCE = await _getBalance();

    if (START_BALANCE == 0) {
      START_BALANCE = CURRENT_BALANCE;
    }

    _checkEquityProtection();

    if (KILL_SWITCH) {
      return Response.json(
        body: {"status": "equity protection triggered"},
      );
    }

    // ================= MARKET ANALYSIS =================
    print("========== TRADE CHECK ==========");

    final analysis =
        MarketAnalysisService.instance.latestFor(symbol);

    print("Symbol: $symbol");
    print("Analysis found: ${analysis != null}");

    if (analysis != null) {
      print("Valid Trade: ${analysis.isValidTrade}");
    }

    if (analysis == null || analysis.isValidTrade == false) {
      return Response.json(body: {
        "status": "market rejected signal",
        "reason": analysis == null ? "no_analysis_data" : "invalid_trade"
      });
    }

    // ================= TRADE VALUES =================
    final deriv = DerivService.instance;

    final entry = (json['entry'] as num).toDouble();
    final sl = (json['stopLoss'] as num).toDouble();
    final tp = (json['takeProfit'] as num).toDouble();

    final isBuy = direction.toUpperCase() == "BUY";
    final stake = _calculateStake(confidence, CURRENT_BALANCE);

    // ================= EXECUTE TRADE =================
    final contractId = await deriv.placeTrade(
      symbol,
      isBuy,
      stake: stake,
    );

    if (contractId == null) {
      return Response.json(
        statusCode: 500,
        body: {"error": "trade failed"},
      );
    }

    final trade = ActiveTrade(
      contractId: contractId,
      pair: symbol,
      buy: isBuy,
      entry: entry,
      sl: sl,
      tp: tp,
      current: entry,
    );

    _activeTrades[contractId] = trade;
    _subscribeToTrade(trade);

    return Response.json(body: {
      "status": "EXECUTED",
      "symbol": symbol,
      "direction": direction,
      "contractId": contractId,
      "stake": stake,
      "balance": CURRENT_BALANCE,
    });

  } catch (e) {
    return Response.json(
      statusCode: 500,
      body: {"error": "$e"},
    );
  }
}

/// ================= STAKE =================
double _calculateStake(double confidence, double balance) {
  final baseRisk = balance * 0.01;

  if (confidence > 0.88) return baseRisk * 1.5;
  if (confidence > 0.80) return baseRisk;
  if (confidence > 0.75) return baseRisk * 0.7;

  return baseRisk * 0.5;
}

/// ================= SUBSCRIBE =================
void _subscribeToTrade(ActiveTrade trade) {
  final deriv = DerivService.instance;

  final sub = deriv.subscribeContract(
    trade.contractId,
    (tick) async {
      if (trade.closed) return;

      final price =
          (tick['price'] as num? ?? 0).toDouble();

      trade.current = price;

      final risk = (trade.entry - trade.sl).abs();
      if (risk == 0) return;

     double rr;

if (trade.buy) {
  rr = (price - trade.entry) / risk;
} else {
  rr = (trade.entry - price) / risk;
}

      if (!trade.breakeven && rr >= 1) {
        trade.sl = trade.entry;
        trade.breakeven = true;
      }
if (rr >= TRAILING_TRIGGER_RR) {
  if (trade.buy) {
    final newSl =
        trade.entry + (risk * TRAILING_STEP_RR);

    if (newSl > trade.sl) {
      trade.sl = newSl;
    }
  } else {
    final newSl =
        trade.entry - (risk * TRAILING_STEP_RR);

    if (newSl < trade.sl) {
      trade.sl = newSl;
    }
  }
}
if (ENABLE_PARTIAL_TP &&
    rr >= PARTIAL_TP_RR &&
    !trade.breakeven) {
  print(
    "📈 PARTIAL TP TRIGGERED ${trade.contractId}",
  );
}
      final tpHit = trade.buy
          ? price >= trade.tp
          : price <= trade.tp;

      final slHit = trade.buy
          ? price <= trade.sl
          : price >= trade.sl;

      if (tpHit || slHit) {
        await _closeTrade(
          trade,
          reason: tpHit ? "TP" : "SL",
        );
      }
    },
  );

  _subscriptions[trade.contractId] = sub;
}

/// ================= CLOSE =================
Future<void> _closeTrade(
  ActiveTrade trade, {
  required String reason,
}) async {
  if (trade.closed) return;

  trade.closed = true;

  try {
    await DerivService.instance
        .closeTradeById(trade.contractId);
  } catch (_) {}

  _subscriptions[trade.contractId]?.cancel();
  _subscriptions.remove(trade.contractId);
  _activeTrades.remove(trade.contractId);

  if (reason == "SL") {
    lossStreak++;
  } else {
    lossStreak = 0;
  }

  CURRENT_BALANCE = await _getBalance();
  _checkEquityProtection();
_checkDailyLimits();

  print("📊 LOSS STREAK: $lossStreak");
  print("💰 BALANCE: $CURRENT_BALANCE");
}