import 'package:dart_frog/dart_frog.dart';
import '../services/market_analysis_service.dart';

Future<Response> onRequest(RequestContext context) async {
  final pair = context.request.uri.queryParameters['pair'] ?? 'V75';
  final analysis = MarketAnalysisService.instance.latestFor(pair);

  if (analysis == null) {
    return Response.json(
      statusCode: 200,
      body: {
        "pair": pair,
        "status": "waiting",
        "message": "No analysis available yet"
      },
    );
  }

  final entry = analysis.candles.isNotEmpty ? analysis.candles.last.close : 0.0;

  final signal = {
    "pair": pair,
    "canBuy": analysis.canBuy,
    "canSell": analysis.canSell,
    "bias": analysis.biasIsBuy ? "BUY" : "SELL",
    "entry": entry,
    "stopLoss": analysis.stopLoss,
    "takeProfit": analysis.takeProfit,
    "conditionsMet": analysis.conditionsMet,
    "failedConditions": analysis.reasonsFailed,
    "timestamp": DateTime.now().toIso8601String(),
  };

  return Response.json(
    statusCode: 200,
    body: signal,
  );
}
