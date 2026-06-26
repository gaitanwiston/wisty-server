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

/// ================= EQUITY =================
double START_BALANCE = 0;
double CURRENT_BALANCE = 0;
double MAX_DRAWDOWN_PERCENT = 25;
int MAX_LOSS_STREAK = 3;
int lossStreak = 0;

bool KILL_SWITCH = false;

/// ================= TRADE MODEL =================
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
  if (context.request.method == HttpMethod.get) {
    return Response.json(
      body: {
        "success": true,
        "active_trades": _activeTrades.length,
      },
    );
  }

  if (context.request.method == HttpMethod.post) {
    final body = await context.request.json();
    return _handleSignal(body);
  }

  return Response(statusCode: 405);
}

/// ================= HANDLE SIGNAL =================
Future<Response> _handleSignal(Map<String, dynamic> json) async {
  try {
    if (KILL_SWITCH || !AUTO_TRADING_ENABLED) {
      return Response.json(body: {"status": "BOT_DISABLED"});
    }

    if (json['type'] != 'signal') {
      return Response.json(
        statusCode: 400,
        body: {"error": "INVALID_PAYLOAD"},
      );
    }

    final symbolRaw = json['symbol']?.toString() ?? '';
    final direction = json['direction']?.toString() ?? '';
    final confidence = (json['confidence'] as num?)?.toDouble() ?? 0.0;
    final timestamp = json['timestamp']?.toString() ?? '';

    final symbol = symbolRaw.toUpperCase().trim();
    final signalId = "${symbol}_$timestamp";

    print("\n══════════════════════════════");
    print("📥 TRADE SIGNAL");
    print("══════════════════════════════");
    print("SYMBOL: $symbol");
    print("DIRECTION: $direction");
    print("CONFIDENCE: $confidence");

    if (_processedSignals.contains(signalId)) {
      return Response.json(body: {"status": "DUPLICATE"});
    }
    _processedSignals.add(signalId);

    if (confidence < MIN_CONFIDENCE) {
      print("❌ REJECTED → LOW CONFIDENCE");
      return Response.json(body: {"status": "LOW_CONFIDENCE"});
    }

    if (_activeTrades.length >= MAX_TRADES) {
      return Response.json(body: {"status": "MAX_TRADES"});
    }

    CURRENT_BALANCE = await _getBalance();

    if (START_BALANCE == 0) {
      START_BALANCE = CURRENT_BALANCE;
    }

    _checkEquityProtection();
    _checkDailyLimits();

    if (KILL_SWITCH) {
      return Response.json(body: {"status": "KILL_SWITCH_ACTIVE"});
    }

    /// ================= ANALYSIS LOOKUP =================
    final service = MarketAnalysisService.instance;

    print("\n🧠 ANALYSIS LOOKUP");
    print("CACHE KEYS: ${service.latestKeys}");

    final analysis = service.latestFor(symbol);

    print("FOUND ANALYSIS: ${analysis != null}");

    if (analysis == null) {
      print("❌ NO ANALYSIS FOUND");
      return Response.json(
        body: {"status": "REJECTED", "reason": "NO_ANALYSIS"},
      );
    }

    print("CAN BUY: ${analysis.canBuy}");
    print("CAN SELL: ${analysis.canSell}");

    if (!analysis.isValidTrade) {
      print("❌ INVALID ANALYSIS");
      return Response.json(
        body: {"status": "REJECTED", "reason": "INVALID_ANALYSIS"},
      );
    }

    print("✅ ANALYSIS PASSED");

    /// ================= TRADE EXECUTION =================
    final deriv = DerivService.instance;

    final entry = (json['entry'] as num).toDouble();
    final sl = (json['stopLoss'] as num).toDouble();
    final tp = (json['takeProfit'] as num).toDouble();

    final isBuy = direction.toUpperCase() == "BUY";
    final stake = _calculateStake(confidence, CURRENT_BALANCE);

    print("\n🚀 EXECUTING TRADE");
    print("PAIR: $symbol");
    print("TYPE: ${isBuy ? "BUY" : "SELL"}");
    print("ENTRY: $entry SL: $sl TP: $tp");
    print("STAKE: $stake");

    final contractId = await deriv.placeTrade(
      symbol,
      isBuy,
      stake: stake,
    );

    if (contractId == null) {
      print("❌ TRADE FAILED");
      return Response.json(
        statusCode: 500,
        body: {"error": "TRADE_FAILED"},
      );
    }

    print("🔥 TRADE EXECUTED → $contractId");

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
      "contractId": contractId,
      "symbol": symbol,
      "balance": CURRENT_BALANCE,
    });

  } catch (e) {
    print("🔥 ERROR: $e");
    return Response.json(
      statusCode: 500,
      body: {"error": "$e"},
    );
  }
}

/// ================= BALANCE =================
Future<double> _getBalance() async {
  final deriv = DerivService.instance;

  if (!deriv.isConnected) {
    await deriv.connect();
  }

  return deriv.getBalance();
}

/// ================= EQUITY PROTECTION =================
void _checkEquityProtection() {
  if (START_BALANCE == 0) return;

  final drawdown =
      ((START_BALANCE - CURRENT_BALANCE) / START_BALANCE) * 100;

  if (drawdown >= MAX_DRAWDOWN_PERCENT) {
    KILL_SWITCH = true;
    AUTO_TRADING_ENABLED = false;
    print("🚨 DRAWDOWN HIT → BOT STOPPED ($drawdown%)");
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

  final pnl =
      ((CURRENT_BALANCE - DAY_START_BALANCE) / DAY_START_BALANCE) * 100;

  if (pnl >= DAILY_PROFIT_TARGET_PERCENT) {
    AUTO_TRADING_ENABLED = false;
    KILL_SWITCH = true;
    print("🎯 DAILY TARGET HIT → $pnl%");
  }

  if (pnl <= -DAILY_LOSS_LIMIT_PERCENT) {
    AUTO_TRADING_ENABLED = false;
    KILL_SWITCH = true;
    print("🛑 DAILY LOSS HIT → $pnl%");
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

      final price = (tick['price'] as num? ?? 0).toDouble();
      trade.current = price;

      final risk = (trade.entry - trade.sl).abs();
      if (risk == 0) return;

      final rr = trade.buy
          ? (price - trade.entry) / risk
          : (trade.entry - price) / risk;

      if (!trade.breakeven && rr >= 1) {
        trade.sl = trade.entry;
        trade.breakeven = true;
      }

      final tpHit = trade.buy ? price >= trade.tp : price <= trade.tp;
      final slHit = trade.buy ? price <= trade.sl : price >= trade.sl;

      if (tpHit || slHit) {
        await _closeTrade(trade, reason: tpHit ? "TP" : "SL");
      }
    },
  );

  _subscriptions[trade.contractId] = sub;
}

/// ================= CLOSE =================
Future<void> _closeTrade(ActiveTrade trade, {required String reason}) async {
  if (trade.closed) return;

  trade.closed = true;

  try {
    await DerivService.instance.closeTradeById(trade.contractId);
  } catch (_) {}

  _subscriptions[trade.contractId]?.cancel();
  _activeTrades.remove(trade.contractId);

  if (reason == "SL") lossStreak++; else lossStreak = 0;

  CURRENT_BALANCE = await _getBalance();
  _checkEquityProtection();
  _checkDailyLimits();

  print("\n========== TRADE CLOSED ==========");
  print("CONTRACT: ${trade.contractId}");
  print("REASON: $reason");
  print("BALANCE: $CURRENT_BALANCE");
}