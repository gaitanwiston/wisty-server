import 'dart:math';
import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';
import '../services/market_analysis_service.dart';
//import '../models/candle.dart'; // ✅ muhimu sana

/// ================= GLOBAL STORAGE =================
final Map<String, Map<String, ActiveTrade>> _userTrades = {};
final Map<String, bool> _tradeLocks = {};

/// ================= ACTIVE TRADE MODEL =================
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

/// ================= ROUTE HANDLER =================
Future<Response> onRequest(RequestContext context) async {
  final userId = context.request.headers['x-user-id'] ?? 'guest';

  switch (context.request.method) {
    case HttpMethod.post:
      return _openTrade(context, userId);
    case HttpMethod.get:
      return _getActiveTrades(userId);
    default:
      return Response(statusCode: 405, body: 'Method Not Allowed');
  }
}

/// ================= OPEN TRADE =================
Future<Response> _openTrade(RequestContext context, String userId) async {
  Map<String, dynamic> body = {};

  // ✅ Safe JSON parsing
  try {
    body = await context.request.json();
  } catch (_) {
    return Response.json(
      statusCode: 400,
      body: {'error': 'Invalid JSON body'},
    );
  }

  final pairRaw = (body['pair'] as String?)?.toUpperCase();
  final action = (body['action'] as String?)?.toUpperCase();
  final stake = (body['stake'] as num?)?.toDouble();

  if (pairRaw == null || action == null || stake == null) {
    return Response.json(
      statusCode: 400,
      body: {'error': 'Missing parameters'},
    );
  }

  final pair = _normalizePair(pairRaw);
  final trades = _userTrades.putIfAbsent(userId, () => {});
  final lockKey = '$userId:$pair';

  // ✅ Lock system
  if (_tradeLocks[lockKey] == true) {
    return Response.json(
      statusCode: 429,
      body: {'error': 'Trade already processing'},
    );
  }
  _tradeLocks[lockKey] = true;

  try {
    if (trades.containsKey(pair)) {
      return Response.json(
        statusCode: 400,
        body: {'error': 'Trade already active'},
      );
    }

    final deriv = DerivService.instance;

    if (!deriv.isConnected) {
      await deriv.connect();
    }

    // ✅ Open trade
    final contractId =
        await deriv.placeTrade(pair, action == "BUY", stake: stake);

    if (contractId == null) {
      return Response.json(
        statusCode: 500,
        body: {'error': 'Trade failed'},
      );
    }

    // ✅ Entry price
    double entryPrice = 0.0;
    try {
      entryPrice = await deriv.getLastPrice(pair) ?? 0.0;
    } catch (_) {}

    // ✅ FIXED: Candle conversion (important)
    final raw = MarketAnalysisService.instance.latestFor(pair);

    final candles = (raw?.candles ?? []).map((c) => Candle(
          epoch: c.epoch,
          open: c.open,
          high: c.high,
          low: c.low,
          close: c.close,
          volume: c.volume,
        )).toList();

    final atr = candles.length > 1
        ? MarketAnalysisService.instance.calcATR(candles, 14)
        : 0.002;

    // ✅ Create trade
    final trade = ActiveTrade(
      buy: action == "BUY",
      stake: stake,
      contractId: contractId,
      pair: pair,
      userId: userId,
      entryPrice: entryPrice,
      sl: action == "BUY"
          ? entryPrice - atr
          : entryPrice + atr,
      tp: action == "BUY"
          ? entryPrice + atr * 3
          : entryPrice - atr * 3,
    );

    trades[pair] = trade;

    print("🚀 OPEN: $pair @ $entryPrice");

    // ✅ FIXED: no StreamSubscription (void issue solved)
    deriv.subscribeContract(contractId, (tick) async {
      try {
        if (trade.closed) return;

        final rawPrice = tick['price'] ?? tick['quote'] ?? 0;
        final price = rawPrice is num
            ? rawPrice.toDouble()
            : double.tryParse('$rawPrice') ?? 0.0;

        trade.currentPrice = price;

        final risk =
            max((trade.entryPrice - trade.sl).abs(), 0.00001);
        final rr = (price - trade.entryPrice).abs() / risk;

        // ✅ Breakeven
        if (!trade.breakeven && rr >= 1) {
          trade.sl = trade.entryPrice;
          trade.breakeven = true;
          print("⚖ Breakeven: $pair");
        }

        // ✅ Partial close
        if (!trade.partialClosed && rr >= 2) {
          trade.partialClosed = true;
          print("💰 Partial: $pair");
        }

        final tpHit = (trade.buy && price >= trade.tp) ||
            (!trade.buy && price <= trade.tp);

        final slHit = (trade.buy && price <= trade.sl) ||
            (!trade.buy && price >= trade.sl);

        if (tpHit || slHit) {
          await deriv.closeTradeById(contractId);

          trade.closed = true;
          trades.remove(pair);
          _tradeLocks.remove(lockKey);

          print("✅ CLOSED: $pair @ $price");
        }
      } catch (e) {
        print("⚠ Error: $e");
      }
    });

    return Response.json(body: {
      'status': 'success',
      'data': {
        'pair': pair,
        'action': action,
        'stake': stake,
        'contractId': contractId,
        'entryPrice': trade.entryPrice,
        'sl': trade.sl,
        'tp': trade.tp,
      }
    });
  } finally {
    final userMap = _userTrades[userId];
    if (userMap == null || !userMap.containsKey(pair)) {
      _tradeLocks.remove(lockKey);
    }
  }
}

/// ================= GET ACTIVE TRADES =================
Future<Response> _getActiveTrades(String userId) async {
  final trades = _userTrades[userId] ?? {};

  return Response.json(
    body: trades.values.map((t) => {
          'contractId': t.contractId,
          'pair': t.pair,
          'buy': t.buy,
          'stake': t.stake,
          'entryPrice': t.entryPrice,
          'sl': t.sl,
          'tp': t.tp,
          'currentPrice': t.currentPrice,
          'breakeven': t.breakeven,
          'partialClosed': t.partialClosed,
          'closed': t.closed,
        }).toList(),
  );
}

/// ================= HELPERS =================
String _normalizePair(String p) {
  p = p.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
  while (p.startsWith('FRXFRX')) {
    p = p.substring(3);
  }
  if (!p.startsWith('FRX')) {
    p = 'FRX$p';
  }
  return p;
}