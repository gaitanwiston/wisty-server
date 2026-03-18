import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_frog/dart_frog.dart';
import '../models/market_analysis_result.dart';
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
  // Ensure WebSocket upgrade
  if (!WebSocketTransformer.isUpgradeRequest(context.request)) {
    return Response.json(
      statusCode: 400,
      body: {"error": "WebSocket upgrade required"},
    );
  }

  // Convert to HttpRequest for WebSocketTransformer
  final httpRequest = context.request as HttpRequest;
  late WebSocket ws;

  try {
    ws = await WebSocketTransformer.upgrade(httpRequest);
  } catch (e) {
    return Response.json(
      statusCode: 500,
      body: {"error": "WebSocket upgrade failed: $e"},
    );
  }

  final pair = (context.request.uri.queryParameters['pair'] ?? 'FRXEURUSD').toUpperCase();
  final service = MarketAnalysisService.instance;

  // Send latest analysis immediately
  final latest = service.latestFor(pair);
  if (latest != null) {
    try {
      ws.add(jsonEncode(_buildPayload(pair, latest)));
    } catch (_) {
      // ignore
    }
  } else {
    ws.add(jsonEncode({
      "pair": pair,
      "status": "waiting",
      "timestamp": DateTime.now().toUtc().toIso8601String(),
    }));
  }

  // Subscribe to live analysis updates
  final sub = service.analysisStream.listen(
    (MarketAnalysisResult analysis) {
      if (analysis.symbol.toUpperCase() == pair) {
        try {
          ws.add(jsonEncode(_buildPayload(pair, analysis)));
        } catch (_) {}
      }
    },
    onError: (err) {
      debugPrint("⚠ Analysis stream error: $err");
    },
  );

  _subscriptions[ws] = sub;
  _clients.putIfAbsent(pair, () => []).add(ws);

  // Heartbeat to detect dead connections
  _startHeartbeat(ws);

  // Listen for client messages
  ws.listen(
    (msg) {
      if (msg == 'ping') ws.add('pong');
      // Future: handle custom messages from client here
    },
    onDone: () => _cleanup(ws, pair),
    onError: (_) => _cleanup(ws, pair),
    cancelOnError: true,
  );

  // 101 Switching Protocols handled by WebSocketTransformer
  return Response(statusCode: 101);
}

/// ================= Payload Builder =================
Map<String, dynamic> _buildPayload(String pair, MarketAnalysisResult analysis) {
  final candles = analysis.candles;
  final entryPrice = candles.isNotEmpty ? candles.last.close : 0.0;

  return {
    "pair": pair,
    "status": "ready",
    "canBuy": analysis.canBuy ?? false,
    "canSell": analysis.canSell ?? false,
    "bias": (analysis.biasIsBuy ?? true) ? "BUY" : "SELL",
    "entryPrice": entryPrice,
    "stopLoss": analysis.stopLoss ?? 0.0,
    "takeProfit": analysis.takeProfit ?? 0.0,
    "conditionsMet": analysis.conditionsMet ?? <String>[],
    "failedConditions": analysis.reasonsFailed ?? <String>[],
    "candleCount": candles.length,
    "timestamp": DateTime.now().toUtc().toIso8601String(),
  };
}

/// ================= Heartbeat =================
void _startHeartbeat(WebSocket ws) {
  _heartbeats[ws]?.cancel();
  _heartbeats[ws] = Timer.periodic(const Duration(seconds: 15), (_) {
    try {
      ws.add('ping');
    } catch (_) {
      _cleanup(ws, _getPair(ws));
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
  if (_clients[pair]?.isEmpty ?? false) _clients.remove(pair);

  _cleanupSocket(ws);
}

void _cleanupSocket(WebSocket ws) {
  try {
    ws.close();
  } catch (_) {}
}

/// ================= Helper =================
String _getPair(WebSocket ws) {
  // Find the pair this ws belongs to
  for (final entry in _clients.entries) {
    if (entry.value.contains(ws)) return entry.key;
  }
  return 'unknown';
}