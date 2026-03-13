import 'package:dart_frog/dart_frog.dart';
import '../services/market_analysis_service.dart';

Future<Response> onRequest(RequestContext context) async {
  try {
    // Pata 'pair' parameter, tumia default kama haipo
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

    // Entry price = close ya last candle, fallback 0.0
    final entry = (analysis.candles.isNotEmpty) ? analysis.candles.last.close : 0.0;

    // Null-safe defaults kwa boolean fields
    final canBuy = analysis.canBuy ?? false;
    final canSell = analysis.canSell ?? false;
    final biasIsBuy = analysis.biasIsBuy ?? true;

    // Null-safe lists
    final conditionsMet = analysis.conditionsMet ?? [];
    final failedConditions = analysis.reasonsFailed ?? [];

    // Construct signal JSON
    final signal = {
      "pair": pair,
      "canBuy": canBuy,
      "canSell": canSell,
      "bias": biasIsBuy ? "BUY" : "SELL",
      "entry": entry,
      "stopLoss": analysis.stopLoss ?? 0.0,
      "takeProfit": analysis.takeProfit ?? 0.0,
      "conditionsMet": conditionsMet,
      "failedConditions": failedConditions,
      "status": "ready",
      "timestamp": DateTime.now().toIso8601String(),
    };

    return Response.json(
      statusCode: 200,
      body: signal,
    );
  } catch (e, st) {
    // Error handling na logging kwa debugging
    return Response.json(
      statusCode: 500,
      body: {
        "error": "Failed to fetch analysis",
        "message": e.toString(),
        "stack": st.toString(),
        "timestamp": DateTime.now().toIso8601String(),
      },
    );
  }
}