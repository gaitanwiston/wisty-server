import 'package:dart_frog/dart_frog.dart';
import '../services/market_analysis_service.dart';

Future<Response> onRequest(RequestContext context) async {
  // Pata pair parameter, tumia default kama haipo
  final pair = context.request.uri.queryParameters['pair']?.toUpperCase() ?? 'V75';

  // Pata latest analysis kutoka MarketAnalysisService
  final analysis = MarketAnalysisService.instance.latestFor(pair);

  // Kama analysis haipo, rudisha "waiting" status badala ya error
  if (analysis == null) {
    return Response.json(
      statusCode: 200,
      body: {
        "pair": pair,
        "status": "waiting",
        "message": "No analysis available yet",
        "timestamp": DateTime.now().toIso8601String(),
      },
    );
  }

  // Entry point ni close ya last candle, au 0.0 kama candles hazipo
  final entry = (analysis.candles.isNotEmpty) ? analysis.candles.last.close : 0.0;

  // Construct signal JSON
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
    "status": "ready",
    "timestamp": DateTime.now().toIso8601String(),
  };

  // Return response
  return Response.json(
    statusCode: 200,
    body: signal,
  );
}