// ======================= routes/trades.dart (DEBUG PRO VERSION) =======================
import 'dart:async';
import 'dart:math';
import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';

final Map<String, Map<String, ActiveTrade>> _userTrades = {};
final Map<String, bool> _tradeLocks = {};

class ActiveTrade {
  final bool buy;
  final double stake;
  final String contractId;
  final String pair;
  final String userId;

  double entryPrice;
  double sl;
  double tp;
  double currentPrice;

  bool breakeven = false;
  bool partialClosed = false;
  bool closed = false;

  DateTime lastAnalysis = DateTime.now();
  List? cachedCandles;

  ActiveTrade({
    required this.buy,
    required this.stake,
    required this.contractId,
    required this.pair,
    required this.userId,
    required this.entryPrice,
    required this.sl,
    required this.tp,
    this.currentPrice = 0,
  });
}

/// ================= ROUTE =================
Future<Response> onRequest(RequestContext context) async {
  final userId = context.request.headers['x-user-id'] ?? 'guest';

  print("\n==================== REQUEST ====================");
  print("👤 USER: $userId");
  print("📡 METHOD: ${context.request.method}");
  print("================================================\n");

  switch (context.request.method) {
    case HttpMethod.post:
      return _openTrade(context, userId);
    case HttpMethod.get:
      return _getActiveTrades(userId);
    default:
      return Response(statusCode: 405);
  }
}

/// ================= OPEN TRADE =================
Future<Response> _openTrade(RequestContext context, String userId) async {
  Map<String, dynamic> body;

  try {
    body = await context.request.json();
    print("📥 CLIENT DATA: $body");
  } catch (e) {
    print("❌ JSON ERROR: $e");
    return Response.json(statusCode: 400, body: {'error': 'Invalid JSON'});
  }

  final pairRaw = (body['pair'] as String?)?.toUpperCase();
  final action = (body['action'] as String?)?.toUpperCase();
  final stake = (body['stake'] as num?)?.toDouble();

  print("🔍 Parsed -> pair:$pairRaw action:$action stake:$stake");

  if (pairRaw == null || action == null || stake == null) {
    print("❌ Missing params");
    return Response.json(statusCode: 400, body: {'error': 'Missing params'});
  }

  final pair = _normalizePair(pairRaw);
  final trades = _userTrades.putIfAbsent(userId, () => {});
  final lockKey = '$userId:$pair';

  print("🔐 LockKey: $lockKey");

  if (_tradeLocks[lockKey] == true) {
    print("⛔ Trade LOCKED");
    return Response.json(statusCode: 429, body: {'error': 'Trade locked'});
  }

  _tradeLocks[lockKey] = true;

  try {
    if (trades.containsKey(pair)) {
      print("⚠ Already active trade exists");
      return Response.json(statusCode: 400, body: {'error': 'Already active'});
    }

    final deriv = DerivService.instance;

    print("🔌 Checking Deriv connection...");
    if (!deriv.isConnected) {
      print("⚠ Not connected → connecting...");
      await deriv.connect();
    }
    print("✅ Deriv connected");

    /// ================= PLACE TRADE =================
    String? contractId;

    try {
      print("📤 Sending trade to Deriv...");
      print("➡ pair: $pair");
      print("➡ action: $action");
      print("➡ stake: $stake");

      contractId = await deriv.placeTrade(
        pair,
        action == "BUY",
        stake: stake,
      );

      print("📥 Deriv RESPONSE contractId: $contractId");
    } catch (e) {
      print("❌ DERIV ERROR: $e");
      _tradeLocks.remove(lockKey);
      return Response.json(statusCode: 500, body: {'error': 'Deriv error'});
    }

    if (contractId == null) {
      print("❌ Deriv returned NULL contractId");
      _tradeLocks.remove(lockKey);
      return Response.json(statusCode: 500, body: {'error': 'Trade failed'});
    }

    /// ================= ENTRY =================
    double entryPrice = 0;
    try {
      entryPrice = await deriv.getLastPrice(pair);
      print("📊 Entry price: $entryPrice");
    } catch (e) {
      print("⚠ Failed to fetch entry price: $e");
    }

    /// ================= ATR =================
    double atr = 0.002;
    try {
      final candles = await deriv.getCandlesWithTF(pair);
      atr = max(_calcATR(candles, 14), 0.0005);
      print("📈 ATR: $atr");
    } catch (e) {
      print("⚠ ATR error: $e");
    }

    final trade = ActiveTrade(
      buy: action == "BUY",
      stake: stake,
      contractId: contractId,
      pair: pair,
      userId: userId,
      entryPrice: entryPrice,
      sl: action == "BUY" ? entryPrice - atr : entryPrice + atr,
      tp: action == "BUY" ? entryPrice + atr * 3 : entryPrice - atr * 3,
    );

    trades[pair] = trade;

    print("🚀 TRADE STORED LOCALLY");

    /// ================= SAFE CLOSE =================
    Future<void> safeClose(double price) async {
      if (trade.closed) return;

      print("🔴 Closing trade...");
      trade.closed = true;

      try {
        await deriv.closeTradeById(contractId!);
        print("✅ Deriv CLOSE success");
      } catch (e) {
        print("⚠ Close failed, retry...");
        await Future.delayed(const Duration(milliseconds: 300));
        try {
          await deriv.closeTradeById(contractId!);
        } catch (e) {
          print("❌ Close retry failed: $e");
        }
      }

      trades.remove(pair);
      _tradeLocks.remove(lockKey);

      print("✅ TRADE REMOVED LOCAL");
    }

    /// ================= LIVE MANAGEMENT =================
    deriv.subscribeContract(contractId, (tick) async {
      if (trade.closed) return;

      try {
        final raw = tick['price'] ?? tick['quote'] ?? 0;
        final price = raw is num ? raw.toDouble() : double.tryParse('$raw') ?? 0;

        if (price == 0) return;

        trade.currentPrice = price;

        print("📡 TICK $pair → $price");

        final risk = max((trade.entryPrice - trade.sl).abs(), 0.00001);
        final rr = (price - trade.entryPrice).abs() / risk;

        /// ================= EXIT CHECK =================
        final tpHit = trade.buy ? price >= trade.tp : price <= trade.tp;
        final slHit = trade.buy ? price <= trade.sl : price >= trade.sl;

        if (tpHit || slHit) {
          print("🎯 TP/SL HIT");
          await safeClose(price);
        }
      } catch (e) {
        print("⚠ Tick error: $e");
      }
    });

    return Response.json(body: {
      'status': 'success',
      'pair': pair,
      'action': action,
      'entry': entryPrice,
      'sl': trade.sl,
      'tp': trade.tp,
      'contractId': contractId,
    });
  } catch (e) {
    print("❌ SERVER ERROR: $e");
    _tradeLocks.remove(lockKey);
    return Response.json(statusCode: 500, body: {'error': 'Server error'});
  }
}

/// ================= GET =================
Future<Response> _getActiveTrades(String userId) async {
  final trades = _userTrades[userId] ?? {};

  print("📊 FETCH TRADES for $userId → ${trades.length}");

  return Response.json(
    body: trades.values.map((t) => {
          'pair': t.pair,
          'buy': t.buy,
          'entry': t.entryPrice,
          'sl': t.sl,
          'tp': t.tp,
          'price': t.currentPrice,
        }).toList(),
  );
}

/// ================= ATR =================
double _calcATR(List candles, int period) {
  if (candles.length < period + 1) return 0.002;

  double atr = 0;
  for (int i = 1; i <= period; i++) {
    final c = candles[i];
    final prev = candles[i - 1];

    final tr = <double>[
      c.high.toDouble() - c.low.toDouble(),
      (c.high.toDouble() - prev.close.toDouble()).abs(),
      (c.low.toDouble() - prev.close.toDouble()).abs(),
    ].reduce(max);

    atr += tr;
  }

  return atr / period;
}

/// ================= NORMALIZE =================
String _normalizePair(String p) {
  p = p.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
  if (!p.startsWith('FRX')) return 'FRX$p';
  return p;
}