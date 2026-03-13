import 'dart:async';
import 'dart:math';
import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';

// ===== GLOBAL STORAGE =====
// Active trades per userId → Map<pair, ActiveTrade>
final Map<String, Map<String, ActiveTrade>> _userTrades = {};

// Queue to avoid race conditions per pair
final Map<String, bool> _tradeLocks = {};

// ===== ActiveTrade Class =====
class ActiveTrade {
  final bool buy;
  final double stake;
  final String contractId;
  final String pair;
  final String userId;

  double entry; // Entry price
  double sl; // Stop loss price
  double tp; // Take profit price
  double currentPrice = 0;

  bool breakeven = false;
  bool partialClosed = false;
  bool closed = false;

  ActiveTrade({
    required this.buy,
    required this.stake,
    required this.contractId,
    required this.pair,
    required this.userId,
    required this.entry,
    required this.sl,
    required this.tp,
  });
}

// ===== ROUTE HANDLER =====
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

// ===== OPEN TRADE =====
Future<Response> _openTrade(RequestContext context, String userId) async {
  final body = await context.request.json();

  final pair = (body['pair'] as String?)?.toUpperCase();
  final action = (body['action'] as String?)?.toUpperCase(); // "BUY" or "SELL"
  final stake = (body['stake'] as num?)?.toDouble();

  if (pair == null || action == null || stake == null) {
    return Response.json(
      statusCode: 400,
      body: {'error': 'Missing parameters: pair, action, or stake'},
    );
  }

  // Initialize user trades map
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
    // Check if trade already active
    if (trades.containsKey(pair)) {
      return Response.json(
        statusCode: 400,
        body: {'error': 'Trade for $pair already active'},
      );
    }

    final deriv = DerivService.instance;

    // Open contract
    final contractId = action == "BUY"
        ? await deriv.buy(pair: pair, stake: stake)
        : await deriv.sell(pair: pair, stake: stake);

    if (contractId == null) {
      return Response.json(
        statusCode: 500,
        body: {'error': 'Failed to open trade on Deriv'},
      );
    }

    // Placeholder entry price, ideally fetch first live price
    final entryPrice = stake;

    // Setup trade
    final trade = ActiveTrade(
      buy: action == "BUY",
      stake: stake,
      contractId: contractId,
      pair: pair,
      userId: userId,
      entry: entryPrice,
      sl: action == "BUY" ? entryPrice - 0.002 : entryPrice + 0.002,
      tp: action == "BUY" ? entryPrice + 0.006 : entryPrice - 0.006,
    );

    trades[pair] = trade;

    // Subscribe to ticks
    deriv.subscribeContract(contractId, (tick) async {
      if (trade.closed) return;

      final price = (tick['price'] ?? tick['quote'])?.toDouble() ?? 0;
      trade.currentPrice = price;

      final risk = (trade.entry - trade.sl).abs();
      final rr = (price - trade.entry).abs() / max(risk, 0.0001);

      // Breakeven logic
      if (!trade.breakeven && rr >= 1) {
        trade.sl = trade.entry;
        trade.breakeven = true;
      }

      // Partial close logic placeholder
      if (!trade.partialClosed && rr >= 2) {
        trade.partialClosed = true;
        // TODO: implement actual partial close on Deriv
      }

      // TP/SL hit logic
      if ((trade.buy && price >= trade.tp) || (!trade.buy && price <= trade.tp)) {
        await deriv.closeTrade(contractId);
        trade.closed = true;
        trades.remove(pair);
      }

      if ((trade.buy && price <= trade.sl) || (!trade.buy && price >= trade.sl)) {
        await deriv.closeTrade(contractId);
        trade.closed = true;
        trades.remove(pair);
      }
    });

    return Response.json(
      body: {
        'pair': pair,
        'action': action,
        'stake': stake,
        'contractId': contractId,
        'status': 'OPEN',
        'entry': trade.entry,
        'sl': trade.sl,
        'tp': trade.tp,
      },
    );
  } finally {
    _tradeLocks[pair] = false;
  }
}

// ===== GET ACTIVE TRADES =====
Future<Response> _getActiveTrades(String userId) async {
  final trades = _userTrades[userId] ?? {};

  final response = trades.map((pair, t) => MapEntry(pair, {
        'contractId': t.contractId,
        'pair': t.pair,
        'buy': t.buy,
        'stake': t.stake,
        'entry': t.entry,
        'sl': t.sl,
        'tp': t.tp,
        'currentPrice': t.currentPrice,
        'breakeven': t.breakeven,
        'partialClosed': t.partialClosed,
        'closed': t.closed,
      }));

  return Response.json(body: response);
}