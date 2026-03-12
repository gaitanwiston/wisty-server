import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';
import '../models/candle.dart';

Future<Response> onRequest(RequestContext context) async {
  final pair = context.request.uri.queryParameters['pair'] ?? "EURUSD";
  final timeframeStr = context.request.uri.queryParameters['timeframe'] ?? "1"; // default 1 minute

  // Badilisha timeframe kuwa int
  final timeframe = int.tryParse(timeframeStr) ?? 1;

  try {
    // await kwa sababu getCandles ni async
    final candles = await DerivService.instance.getCandles(pair, timeframe: timeframe);

    if (candles.isEmpty) {
      return Response.json(
        statusCode: 404,
        body: {"error": "No candles found for $pair"},
      );
    }

    // sort by epoch (au time)
    candles.sort((a, b) => a.epoch.compareTo(b.epoch));

    final data = candles.map((c) => {
          "time": DateTime.fromMillisecondsSinceEpoch(c.epoch * 1000).toIso8601String(),
          "open": c.open,
          "high": c.high,
          "low": c.low,
          "close": c.close,
        }).toList();

    return Response.json(body: {
      "pair": pair,
      "timeframe": timeframe,
      "candles": data,
    });
  } catch (e, st) {
    return Response.json(
      statusCode: 500,
      body: {
        "error": "Failed to fetch candles",
        "message": e.toString(),
        "stack": st.toString(),
      },
    );
  }
}