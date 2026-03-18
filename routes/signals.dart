import 'dart:async';
import 'dart:convert';
import 'package:dart_frog/dart_frog.dart';
import '../services/market_analysis_service.dart';

final Map<String, WebSocketChannel> _clients = {};
final Map<String, StreamSubscription> _subscriptions = {};

Future<Response> onRequest(RequestContext context) async {
  if (!WebSocketTransformer.isUpgradeRequest(context.request)) {
    return Response.json(
      statusCode: 400,
      body: {"error": "WebSocket upgrade required"},
    );
  }

  final wsChannel = await WebSocketTransformer.upgrade(context.request);
  final queryParams = context.request.uri.queryParameters;
  final pair = (queryParams['pair'] ?? 'FRXEURUSD').toUpperCase();

  final service = MarketAnalysisService.instance;

  // Send current/latest analysis immediately
  final latest = service.latestFor(pair);
  if (latest != null) {
    wsChannel.add(jsonEncode(_buildPayload(pair, latest)));
  } else {
    wsChannel.add(jsonEncode({
      "pair": pair,
      "status": "waiting",
      "timestamp": DateTime.now().toIso8601String(),
    }));
  }

  // Subscribe to live analysis updates
  final sub = service.analysisStream.listen((analysis) {
    if (analysis.symbol == pair) {
      wsChannel.add(jsonEncode(_buildPayload(pair, analysis)));
    }
  });

  // Cleanup on disconnect
  wsChannel.done.then((_) {
    sub.cancel();
  });

  return Response(statusCode: 101); // Switching Protocols
}

/// Build JSON payload from MarketAnalysisResult
Map<String, dynamic> _buildPayload(String pair, dynamic analysis) {
  final candles = analysis.candles;
  final entry = candles.isNotEmpty ? candles.last.close : 0.0;

  return {
    "pair": pair,
    "status": "ready",
    "canBuy": analysis.canBuy ?? false,
    "canSell": analysis.canSell ?? false,
    "bias": (analysis.biasIsBuy ?? true) ? "BUY" : "SELL",
    "entry": entry,
    "stopLoss": analysis.stopLoss ?? 0.0,
    "takeProfit": analysis.takeProfit ?? 0.0,
    "conditionsMet": analysis.conditionsMet ?? <String>[],
    "failedConditions": analysis.reasonsFailed ?? <String>[],
    "candleCount": candles.length,
    "timestamp": DateTime.now().toIso8601String(),
  };
}