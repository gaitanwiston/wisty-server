import 'dart:async';
import 'dart:math';
import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';
import '../services/market_analysis_service.dart';

/// ================= GLOBAL STORAGE =================
// Active trades per userId → Map<pair, ActiveTrade>
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
  final body = await context.request.json();
  final pair = (body['pair'] as String?)?.toUpperCase();
  final action = (body['action'] as String?)?.toUpperCase();
  final stake = (body['stake'] as num?)?.toDouble();

  if (pair == null || action == null || stake == null) {
    return Response.json(
      statusCode: 400,
      body: {'error': 'Missing parameters: pair, action, or stake'},
    );
  }

  final trades = _userTrades.putIfAbsent(userId, () => {});
  final lockKey = '$userId:$pair';

  if (_tradeLocks[lockKey] == true) {
    return Response.json(
      statusCode: 429,
      body: {'error': 'Trade processing in progress for $pair'},
    );
  }
  _tradeLocks[lockKey] = true;

  try {
    if (trades.containsKey(pair)) {
      return Response.json(
        statusCode: 400,
        body: {'error': 'Trade for $pair already active'},
      );
    }

    final deriv = DerivService.instance;
    if (!deriv.isConnected) await deriv.connect();

    final contractId = await deriv.placeTrade(pair, action == "BUY", stake: stake);

    if (contractId == null) {
      return Response.json(
        statusCode: 500,
        body: {'error': 'Failed to open trade on Deriv'},
      );
    }

    // Entry price from last tick, fallback to 0.0
    double entryPrice;
    try {
      final rawPrice = await deriv.getLastPrice(pair);
      entryPrice = rawPrice ?? 0.0;
    } catch (_) {
      entryPrice = 0.0;
    }

    // ATR-based SL/TP if available
    final candles = MarketAnalysisService.instance.latestFor(pair)?.candles ?? [];
    final atr = candles.length > 1 ? MarketAnalysisService.instance._calcATR(candles, 14) : 0.002;

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

    print("[Trade OPEN] $userId $pair $action @ $entryPrice | ContractId: $contractId");

    deriv.subscribeContract(contractId, (tick) async {
      try {
        if (trade.closed) return;

        final rawPrice = tick['price'] ?? tick['quote'];
        final price = (rawPrice is num ? rawPrice.toDouble() : double.tryParse('$rawPrice') ?? 0.0);
        trade.currentPrice = price;

        final risk = max((trade.entryPrice - trade.sl).abs(), 0.00001);
        final rr = (price - trade.entryPrice).abs() / risk;

        if (!trade.breakeven && rr >= 1) {
          trade.sl = trade.entryPrice;
          trade.breakeven = true;
          print("[Breakeven] $userId $pair | SL moved to entryPrice");
        }

        if (!trade.partialClosed && rr >= 2) {
          trade.partialClosed = true;
          print("[Partial Close] $userId $pair | 50% simulated close");
        }

        final tpHit = (trade.buy && price >= trade.tp) || (!trade.buy && price <= trade.tp);
        final slHit = (trade.buy && price <= trade.sl) || (!trade.buy && price >= trade.sl);

        if (tpHit || slHit) {
          await deriv.closeTradeById(contractId);
          trade.closed = true;
          trades.remove(pair);
          _tradeLocks.remove(lockKey);
          print("[Trade CLOSED] $userId $pair | Price: $price | TP/SL hit");
        }
      } catch (e, st) {
        print("⚠ Trade subscription error: $e\n$st");
      }
    });

    return Response.json(body: {
      'pair': pair,
      'action': action,
      'stake': stake,
      'contractId': contractId,
      'status': 'OPEN',
      'entryPrice': trade.entryPrice,
      'sl': trade.sl,
      'tp': trade.tp,
    });
  } finally {
    if (!_userTrades[userId]!.containsKey(pair)) _tradeLocks.remove(lockKey);
  }
}

/// ================= GET ACTIVE TRADES =================
Future<Response> _getActiveTrades(String userId) async {
  final trades = _userTrades[userId] ?? {};

  final response = trades.values.map((t) => {
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
      }).toList();

  return Response.json(body: response);
}