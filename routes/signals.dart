import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import '../models/market_analysis_result.dart';
import '../services/market_analysis_service.dart';

Future<Response> onRequest(RequestContext context) async {
  if (!WebSocketTransformer.isUpgradeRequest(context.request)) {
    return Response(statusCode: 400, body: 'WebSocket connections only');
  }

  final ws = await WebSocketTransformer.upgrade(context.request);
  _handleWebSocket(ws);
  return null; // WebSocket handles communication directly
}

final Map<String, List<WebSocket>> _clients = {};
final Map<WebSocket, StreamSubscription> _subscriptions = {};
final Map<WebSocket, Timer> _heartbeats = {};

void _handleWebSocket(WebSocket ws) {
  final service = MarketAnalysisService.instance;
  var pair = 'FRXEURUSD';

  print('📡 Client connected');

  // Send latest analysis
  void sendLatest() {
    final latest = service.latestFor(pair);
    if (latest != null) ws.add(jsonEncode(_buildPayload(pair, latest)));
  }

  sendLatest();

  // Subscribe to analysis stream
  final sub = service.analysisStream.listen((MarketAnalysisResult analysis) {
    if (analysis.symbol.toUpperCase() == pair) {
      ws.add(jsonEncode(_buildPayload(pair, analysis)));
    }
  }, onError: (err) => print("⚠ Analysis stream error: $err"));

  _subscriptions[ws] = sub;
  _addClient(ws, pair);

  // Heartbeat every 15 seconds
  _heartbeats[ws]?.cancel();
  _heartbeats[ws] = Timer.periodic(const Duration(seconds: 15), (_) {
    try {
      ws.add('ping');
    } catch (_) {
      _cleanup(ws, pair);
    }
  });

  ws.listen(
    (msg) => _handleClientMessage(ws, msg, pair),
    onDone: () => _cleanup(ws, pair),
    onError: (_) => _cleanup(ws, pair),
  );
}

void _handleClientMessage(WebSocket ws, dynamic msg, String currentPair) {
  try {
    final data = jsonDecode(msg);
    if (data['pair'] != null) {
      final newPair = data['pair'].toUpperCase();
      if (newPair != currentPair) {
        print('📩 Switching pair: $currentPair → $newPair');
        _removeClient(ws, currentPair);
        _addClient(ws, newPair);
        currentPair = newPair;

        final latest = MarketAnalysisService.instance.latestFor(newPair);
        if (latest != null) ws.add(jsonEncode(_buildPayload(newPair, latest)));
      }
    }
  } catch (_) {
    if (msg == 'ping') ws.add('pong');
  }

  if (msg == 'ping') ws.add('pong');
}

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
    "conditionsMet": analysis.conditionsMet ?? [],
    "failedConditions": analysis.reasonsFailed ?? [],
    "candleCount": candles.length,
    "timestamp": DateTime.now().toUtc().toIso8601String(),
  };
}

void _addClient(WebSocket ws, String pair) {
  _clients.putIfAbsent(pair, () => []).add(ws);
}

void _removeClient(WebSocket ws, String pair) {
  _clients[pair]?.remove(ws);
  if (_clients[pair]?.isEmpty ?? false) _clients.remove(pair);
}

void _cleanup(WebSocket ws, String pair) {
  print('❌ Client disconnected');
  _subscriptions[ws]?.cancel();
  _subscriptions.remove(ws);

  _heartbeats[ws]?.cancel();
  _heartbeats.remove(ws);

  _removeClient(ws, pair);

  try {
    ws.close();
  } catch (_) {}
}

String _getPair(WebSocket ws) {
  for (final entry in _clients.entries) {
    if (entry.value.contains(ws)) return entry.key;
  }
  return 'unknown';
}