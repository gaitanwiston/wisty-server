import 'dart:async';
import 'dart:math';
import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';

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

  // Prevent concurrent trade on same pair
  if (_tradeLocks[pair] == true) {
    return Response.json(
      statusCode: 429,
      body: {'error': 'Trade processing in progress for $pair'},
    );
  }
  _tradeLocks[pair] = true;

  try {
    if (trades.containsKey(pair)) {
      return Response.json(
        statusCode: 400,
        body: {'error': 'Trade for $pair already active'},
      );
    }

    final deriv = DerivService.instance;
    final contractId = await deriv.placeTrade(pair, action == "BUY", stake: stake);

    if (contractId == null) {
      return Response.json(
        statusCode: 500,
        body: {'error': 'Failed to open trade on Deriv'},
      );
    }

    // Fetch initial entry price from Deriv ticks (simulate if unavailable)
    double entryPrice;
    try {
      entryPrice = await deriv.getLastPrice(pair) ?? stake;
    } catch (_) {
      entryPrice = stake; // fallback
    }

    final trade = ActiveTrade(
      buy: action == "BUY",
      stake: stake,
      contractId: contractId,
      pair: pair,
      userId: userId,
      entryPrice: entryPrice,
      sl: action == "BUY" ? entryPrice - 0.002 : entryPrice + 0.002,
      tp: action == "BUY" ? entryPrice + 0.006 : entryPrice - 0.006,
    );

    trades[pair] = trade;

    print("[Trade OPEN] $userId $pair $action @ $entryPrice | ContractId: $contractId");

    deriv.subscribeContract(contractId, (tick) async {
      if (trade.closed) return;

      final price = (tick['price'] ?? tick['quote'])?.toDouble() ?? 0.0;
      trade.currentPrice = price;

      // Risk/reward calculation
      final risk = max((trade.entryPrice - trade.sl).abs(), 0.0001);
      final rr = (price - trade.entryPrice).abs() / risk;

      // Breakeven logic
      if (!trade.breakeven && rr >= 1) {
        trade.sl = trade.entryPrice;
        trade.breakeven = true;
        print("[Breakeven] $userId $pair | SL moved to entryPrice");
      }

      // Partial close logic simulation
      if (!trade.partialClosed && rr >= 2) {
        trade.partialClosed = true;
        print("[Partial Close] $userId $pair | 50% simulated close");
        // TODO: implement actual partial close on Deriv
      }

      // TP/SL hit logic
      final tpHit = (trade.buy && price >= trade.tp) || (!trade.buy && price <= trade.tp);
      final slHit = (trade.buy && price <= trade.sl) || (!trade.buy && price >= trade.sl);

      if (tpHit || slHit) {
        await deriv.closeTradeById(contractId);
        trade.closed = true;
        trades.remove(pair);
        print("[Trade CLOSED] $userId $pair | Price: $price | TP/SL hit");
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
    _tradeLocks[pair] = false;
  }
}

/// ================= GET ACTIVE TRADES =================
Future<Response> _getActiveTrades(String userId) async {
  final trades = _userTrades[userId] ?? {};

  final response = trades.map((pair, t) => MapEntry(pair, {
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
      }));

  return Response.json(body: response);
}