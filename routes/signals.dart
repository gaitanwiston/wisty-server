import 'dart:async';
import 'dart:convert';
import 'package:dart_frog/dart_frog.dart';
import '../services/market_analysis_service.dart';
import '../models/market_analysis_result.dart';

final Map<String, List<WebSocketSink>> _clients = {};
final Map<WebSocketSink, StreamSubscription> _subscriptions = {};
final Map<WebSocketSink, Timer> _heartbeats = {};

Future<Response> onRequest(RequestContext context) async {
  if (context.request.headers['upgrade']?.toLowerCase() != 'websocket') {
    return Response(statusCode: 400, body: 'Not a WebSocket request');
  }

  return context.webSocket((socket) {
    _handleSocket(socket);
  });
}

void _handleSocket(WebSocketSink socket) {
  final service = MarketAnalysisService.instance;
  String pair = 'FRXEURUSD';

  print('📡 Client connected to /signals');

  void sendLatest() {
    final latest = service.latestFor(pair);
    if (latest != null) {
      socket.add(jsonEncode(_buildPayload(pair, latest)));
    }
  }

  sendLatest();

  // Listen to MarketAnalysisService stream
  final sub = service.analysisStream.listen((analysis) {
    if (analysis.symbol.toUpperCase() == pair) {
      socket.add(jsonEncode(_buildPayload(pair, analysis)));
    }
  });

  _subscriptions[socket] = sub;
  _clients.putIfAbsent(pair, () => []).add(socket);

  // Heartbeat ping
  _heartbeats[socket] = Timer.periodic(
    const Duration(seconds: 15),
    (_) => socket.add('ping'),
  );

  socket.done.then((_) => _cleanup(socket, pair));

  // Listen to messages from client
  socket.listen((msg) {
    pair = _handleClientMessage(socket, msg, pair);
  }, onError: (_) => _cleanup(socket, pair));
}

String _handleClientMessage(WebSocketSink socket, dynamic msg, String currentPair) {
  try {
    final data = jsonDecode(msg);
    if (data['pair'] != null) {
      final newPair = data['pair'].toUpperCase();
      if (newPair != currentPair) {
        _removeClient(socket, currentPair);
        _clients.putIfAbsent(newPair, () => []).add(socket);
        return newPair;
      }
    }
  } catch (_) {}

  if (msg == 'ping') socket.add('pong');

  return currentPair;
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
    "timestamp": DateTime.now().toUtc().toIso8601String(),
  };
}

void _removeClient(WebSocketSink socket, String pair) {
  _clients[pair]?.remove(socket);
  _subscriptions[socket]?.cancel();
  _subscriptions.remove(socket);
  _heartbeats[socket]?.cancel();
  _heartbeats.remove(socket);
}

void _cleanup(WebSocketSink socket, String pair) {
  print('❌ Client disconnected');
  _removeClient(socket, pair);
  try {
    socket.close();
  } catch (_) {}
}