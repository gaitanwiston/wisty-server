import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_frog/dart_frog.dart';
import '../models/market_analysis_result.dart';
import '../services/market_analysis_service.dart';

/// ================= STATE =================
final Map<String, List<WebSocket>> _clients = {};
final Map<WebSocket, StreamSubscription> _subscriptions = {};
final Map<WebSocket, Timer> _heartbeats = {};

/// ================= ROUTE =================
Future<Response> onRequest(RequestContext context) async {
  final request = context.request;

  if (!WebSocketTransformer.isUpgradeRequest(request)) {
    return Response(
      statusCode: 400,
      body: 'Not a WebSocket request',
    );
  }

  final ws = await WebSocketTransformer.upgrade(request);

  final service = MarketAnalysisService.instance;
  String pair = 'FRXEURUSD'; // default

  print('✅ Client connected');

  /// ===== SEND INITIAL DATA =====
  void sendLatest() {
    final latest = service.latestFor(pair);
    if (latest != null) {
      ws.add(jsonEncode(_buildPayload(pair, latest)));
    } else {
      ws.add(jsonEncode({
        "pair": pair,
        "status": "waiting",
        "timestamp": DateTime.now().toUtc().toIso8601String(),
      }));
    }
  }

  sendLatest();

  /// ===== STREAM LISTENER =====
  final sub = service.analysisStream.listen(
    (MarketAnalysisResult analysis) {
      if (analysis.symbol.toUpperCase() == pair) {
        ws.add(jsonEncode(_buildPayload(pair, analysis)));
      }
    },
    onError: (err) => print("⚠ Analysis stream error: $err"),
  );

  _subscriptions[ws] = sub;
  _clients.putIfAbsent(pair, () => []).add(ws);

  /// ===== HEARTBEAT =====
  _heartbeats[ws]?.cancel();
  _heartbeats[ws] = Timer.periodic(const Duration(seconds: 15), (_) {
    try {
      ws.add('ping');
    } catch (_) {
      _cleanup(ws, _getPair(ws));
    }
  });

  /// ===== CLIENT LISTENER =====
  ws.listen(
    (msg) {
      try {
        final data = jsonDecode(msg);

        if (data['pair'] != null) {
          final newPair = data['pair'].toUpperCase();
          if (newPair != pair) {
            print('📩 Switching pair: $pair → $newPair');
            _removeClient(ws, pair);
            pair = newPair;
            _addClient(ws, pair);
            sendLatest();
          }
        }

        if (msg == 'ping') ws.add('pong');
      } catch (_) {
        if (msg == 'ping') ws.add('pong');
      }
    },
    onDone: () => _cleanup(ws, pair),
    onError: (_) => _cleanup(ws, pair),
  );

  // Dart Frog expects Response, but WebSocket is upgraded already
  return Response(statusCode: 101);
}

/// ================= PAYLOAD =================
Map<String, dynamic> _buildPayload(
  String pair,
  MarketAnalysisResult analysis,
) {
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

/// ================= CLIENT MGMT =================
void _addClient(WebSocket ws, String pair) {
  _clients.putIfAbsent(pair, () => []).add(ws);
}

void _removeClient(WebSocket ws, String pair) {
  _clients[pair]?.remove(ws);
  if (_clients[pair]?.isEmpty ?? false) {
    _clients.remove(pair);
  }
}

/// ================= CLEANUP =================
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

/// ================= HELPER =================
String _getPair(WebSocket ws) {
  for (final entry in _clients.entries) {
    if (entry.value.contains(ws)) return entry.key;
  }
  return 'unknown';
}