import 'dart:async';
import 'dart:convert';
import 'package:dart_frog/dart_frog.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../services/market_analysis_service.dart';
import '../models/market_analysis_result.dart';

final Map<String, List<WebSocketChannel>> _clients = {};
final Map<WebSocketChannel, StreamSubscription> _subscriptions = {};
final Map<WebSocketChannel, Timer> _heartbeats = {};

Handler onRequest(RequestContext context) {
  return webSocketHandler((WebSocketChannel socket) {
    _handleSocket(socket);
  });
}

void _handleSocket(WebSocketChannel socket) {
  final service = MarketAnalysisService.instance;
  String pair = 'FRXEURUSD';

  print('📡 Client connected to /signals');

  void sendLatest() {
    final latest = service.latestFor(pair);
    if (latest != null) {
      socket.sink.add(jsonEncode(_buildPayload(pair, latest)));
    }
  }

  sendLatest();

  final sub = service.analysisStream.listen((analysis) {
    if (analysis.symbol.toUpperCase() == pair) {
      socket.sink.add(jsonEncode(_buildPayload(pair, analysis)));
    }
  });

  _subscriptions[socket] = sub;
  _clients.putIfAbsent(pair, () => []).add(socket);

  _heartbeats[socket] = Timer.periodic(
    const Duration(seconds: 15),
    (_) => socket.sink.add('ping'),
  );

  socket.stream.listen(
    (msg) {
      pair = _handleClientMessage(socket, msg, pair);
    },
    onDone: () => _cleanup(socket, pair),
    onError: (_) => _cleanup(socket, pair),
  );
}

String _handleClientMessage(
    WebSocketChannel socket, dynamic msg, String currentPair) {
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

  if (msg == 'ping') socket.sink.add('pong');

  return currentPair;
}

Map<String, dynamic> _buildPayload(
    String pair, MarketAnalysisResult analysis) {
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

void _removeClient(WebSocketChannel socket, String pair) {
  _clients[pair]?.remove(socket);
  _subscriptions[socket]?.cancel();
  _subscriptions.remove(socket);
  _heartbeats[socket]?.cancel();
  _heartbeats.remove(socket);
}

void _cleanup(WebSocketChannel socket, String pair) {
  print('❌ Client disconnected');
  _removeClient(socket, pair);
  try {
    socket.sink.close();
  } catch (_) {}
}