import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_frog/dart_frog.dart';
import '../services/market_analysis_service.dart';

/// ================= WebSocket Server =================
// Multiple clients per pair
final Map<String, List<WebSocket>> _clients = {};
// Subscriptions per WebSocket
final Map<WebSocket, StreamSubscription> _subscriptions = {};
// Heartbeat timers
final Map<WebSocket, Timer> _heartbeats = {};

/// ================= WebSocket Handler =================
Future<Response> onRequest(RequestContext context) async {
  if (!WebSocketTransformer.isUpgradeRequest(context.request)) {
    return Response.json(
      statusCode: 400,
      body: {"error": "WebSocket upgrade required"},
    );
  }

  final ws = await WebSocketTransformer.upgrade(context.request);
  final queryParams = context.request.uri.queryParameters;
  final pair = (queryParams['pair'] ?? 'FRXEURUSD').toUpperCase();

  final service = MarketAnalysisService.instance;

  // Send current/latest analysis immediately
  final latest = service.latestFor(pair);
  try {
    if (latest != null) {
      ws.add(jsonEncode(_buildPayload(pair, latest)));
    } else {
      ws.add(jsonEncode({
        "pair": pair,
        "status": "waiting",
        "timestamp": DateTime.now().toUtc().toIso8601String(),
      }));
    }
  } catch (_) {}

  // Subscribe to live analysis updates
  final sub = service.analysisStream.listen((MarketAnalysisResult analysis) {
    if (analysis.symbol == pair) {
      try {
        ws.add(jsonEncode(_buildPayload(pair, analysis)));
      } catch (_) {}
    }
  });

  // Store client and subscription
  _subscriptions[ws] = sub;
  _clients.putIfAbsent(pair, () => []).add(ws);

  // Setup heartbeat to detect dead connections
  _startHeartbeat(ws);

  // Listen for client messages (optional, e.g., for pings or commands)
  ws.listen(
    (msg) {
      if (msg == 'ping') {
        ws.add('pong');
      }
    },
    onDone: () => _cleanup(ws, pair),
    onError: (_) => _cleanup(ws, pair),
    cancelOnError: true,
  );

  return Response(statusCode: 101);
}

/// ================= Payload Builder =================
Map<String, dynamic> _buildPayload(String pair, MarketAnalysisResult analysis) {
  final candles = analysis.candles;
  final entry = candles.isNotEmpty ? candles.last.close : 0.0;

  return {
    "pair": pair,
    "status": "ready",
    "canBuy": analysis.canBuy,
    "canSell": analysis.canSell,
    "bias": (analysis.biasIsBuy) ? "BUY" : "SELL",
    "entry": entry,
    "stopLoss": analysis.stopLoss,
    "takeProfit": analysis.takeProfit,
    "conditionsMet": analysis.conditionsMet,
    "failedConditions": analysis.reasonsFailed,
    "candleCount": candles.length,
    "timestamp": DateTime.now().toUtc().toIso8601String(),
  };
}

/// ================= Heartbeat =================
void _startHeartbeat(WebSocket ws) {
  // cancel old timer if exists
  _heartbeats[ws]?.cancel();

  // send ping every 15 seconds
  _heartbeats[ws] = Timer.periodic(const Duration(seconds: 15), (_) {
    try {
      ws.add('ping');
    } catch (_) {
      // if sending fails, cleanup
      _cleanupSocket(ws);
    }
  });
}

/// ================= Cleanup =================
void _cleanup(WebSocket ws, String pair) {
  _subscriptions[ws]?.cancel();
  _subscriptions.remove(ws);

  _heartbeats[ws]?.cancel();
  _heartbeats.remove(ws);

  _clients[pair]?.remove(ws);
  if (_clients[pair]?.isEmpty ?? false) {
    _clients.remove(pair);
  }

  _cleanupSocket(ws);
}

void _cleanupSocket(WebSocket ws) {
  try {
    ws.close();
  } catch (_) {}
}