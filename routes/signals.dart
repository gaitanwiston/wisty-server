import 'package:dart_frog/dart_frog.dart';
import '../services/market_analysis_service.dart';

Future<Response> onRequest(RequestContext context) async {
  final pair =
      context.request.uri.queryParameters['pair']?.toUpperCase() ?? 'FRXEURUSD';

  try {
    final service = MarketAnalysisService.instance;

    // pata analysis iliyopo tayari (non-blocking)
    final analysis = service.latestFor(pair);

    // kama bado haijawa ready
    if (analysis == null) {
      return Response.json(
        body: {
          "pair": pair,
          "status": "waiting",
          "canBuy": false,
          "canSell": false,
          "entry": 0.0,
          "stopLoss": 0.0,
          "takeProfit": 0.0,
          "probability": 0,
          "conditionsMet": [],
          "failedConditions": [],
          "timestamp": DateTime.now().toIso8601String(),
        },
      );
    }

    // ---------- SAFE DATA ----------
    final candles = analysis.candles;
    final entry =
        candles.isNotEmpty ? (candles.last.close ?? 0.0) : 0.0;

    final canBuy = analysis.canBuy ?? false;
    final canSell = analysis.canSell ?? false;

    final biasIsBuy = analysis.biasIsBuy ?? true;

    final stopLoss = analysis.stopLoss ?? 0.0;
    final takeProfit = analysis.takeProfit ?? 0.0;

    final probability = analysis.probability ?? 0;

    final conditionsMet = analysis.conditionsMet ?? <String>[];
    final failedConditions = analysis.reasonsFailed ?? <String>[];

    // ---------- RESPONSE ----------
    final response = {
      "pair": pair,
      "status": "ready",

      "canBuy": canBuy,
      "canSell": canSell,

      "bias": biasIsBuy ? "BUY" : "SELL",

      "entry": entry,
      "stopLoss": stopLoss,
      "takeProfit": takeProfit,

      "probability": probability,

      "conditionsMet": conditionsMet,
      "failedConditions": failedConditions,

      "candleCount": candles.length,

      "timestamp": DateTime.now().toIso8601String(),
    };

    return Response.json(body: response);
  } catch (e, st) {
    // error logging safe
    print("⚠ SIGNALS ERROR [$pair]: $e");

    return Response.json(
      statusCode: 500,
      body: {
        "pair": pair,
        "status": "error",
        "message": e.toString(),
        "stack": st.toString(),
        "timestamp": DateTime.now().toIso8601String(),
      },
    );
  }
}