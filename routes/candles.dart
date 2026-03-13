import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';
import '../models/candle.dart';

Future<Response> onRequest(RequestContext context) async {
  // Pata query parameters na tumia default kama hazipo
  final pair = context.request.uri.queryParameters['pair']?.toUpperCase() ?? 'EURUSD';
  final timeframe = int.tryParse(context.request.uri.queryParameters['timeframe'] ?? '1') ?? 1;

  try {
    // Pata candles kutoka DerivService
    final candles = await DerivService.instance.getCandles(pair, timeframe: timeframe);

    // Kama hakuna candles, rudisha 404
    if (candles.isEmpty) {
      return Response.json(
        statusCode: 404,
        body: {'error': 'No candles found for $pair'},
      );
    }

    // Panga candles kwa ascending time
    candles.sort((a, b) => a.epoch.compareTo(b.epoch));

    // Convert candles kwa format ya JSON
    final candleData = candles.map((c) {
      return {
        'time': DateTime.fromMillisecondsSinceEpoch(c.epoch * 1000).toIso8601String(),
        'open': c.open,
        'high': c.high,
        'low': c.low,
        'close': c.close,
      };
    }).toList();

    // Rudisha response
    return Response.json(
      body: {
        'pair': pair,
        'timeframe': timeframe,
        'candles': candleData,
      },
    );
  } catch (e, st) {
    // Error handling bora na stack trace
    return Response.json(
      statusCode: 500,
      body: {
        'error': 'Failed to fetch candles',
        'message': e.toString(),
        'stack': st.toString(),
      },
    );
  }
}