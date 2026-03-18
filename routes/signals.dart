import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shelf_web_socket/shelf_web_socket.dart';
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
Handler websocketHandler({String defaultPair = 'FRXEURUSD'}) {
  return webSocketHandler((WebSocket ws) {
    final pair = defaultPair.toUpperCase();
    final service = MarketAnalysisService.instance;

    // Send latest analysis immediately
    final latest = service.latestFor(pair);
    if (latest != null) {
      try {
        ws.add(jsonEncode(_buildPayload(pair, latest)));
      } catch (_) {}
    } else {
      ws.add(jsonEncode({
        "pair": pair,
        "status": "waiting",
        "timestamp": DateTime.now().toUtc().toIso8601String(),
      }));
    }

    // Subscribe to live analysis
    final sub = service.analysisStream.listen(
      (MarketAnalysisResult analysis) {
        if (analysis.symbol.toUpperCase() == pair) {
          try {
            ws.add(jsonEncode(_buildPayload(pair, analysis)));
          } catch (_) {}
        }
      },
      onError: (err) {
        print("⚠ Analysis stream error: $err");
      },
    );

    _subscriptions[ws] = sub;
    _clients.putIfAbsent(pair, () => []).add(ws);

    // Heartbeat
    _startHeartbeat(ws);

    // Listen for client messages
    ws.listen(
      (msg) {
        if (msg == 'ping') ws.add('pong');
      },
      onDone: () => _cleanup(ws, pair),
      onError: (_) => _cleanup(ws, pair),
    );
  });
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

  try {
    ws.close();
  } catch (_) {}
}

/// ================= Helper =================
String _getPair(WebSocket ws) {
  for (final entry in _clients.entries) {
    if (entry.value.contains(ws)) return entry.key;
  }
  return 'unknown';
}