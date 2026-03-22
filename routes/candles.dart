// routes/candles.dart
import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';
import '../models/candle.dart';

Future<Response> onRequest(RequestContext context) async {
  final nowIso = DateTime.now().toUtc().toIso8601String();

  final pair =
      context.request.uri.queryParameters['pair']?.toUpperCase() ?? 'EURUSD';
  final timeframe =
      int.tryParse(context.request.uri.queryParameters['timeframe'] ?? '1') ?? 1;

  if (timeframe <= 0) {
    return Response.json(
      statusCode: 400,
      body: {'success': false, 'error': 'Invalid timeframe'},
    );
  }

  print("📊 /candles hit → $pair TF:$timeframe at $nowIso");

  try {
    final deriv = DerivService.instance;
    if (!deriv.isConnected) await deriv.connect();

    final candleList = await deriv.getCandles(pair, timeframe: timeframe);

    // Avoid 404, return empty array if no data
    final candleData = candleList.map((c) {
      final epochSeconds = _parseEpoch(c.epoch);
      return {
        'time': DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true)
            .toIso8601String(),
        'open': c.open,
        'high': c.high,
        'low': c.low,
        'close': c.close,
      };
    }).toList();

    return Response.json(
      body: {
        'success': true,
        'pair': pair,
        'timeframe': timeframe,
        'count': candleData.length,
        'candles': candleData,
        'timestamp': nowIso,
      },
    );
  } catch (e, st) {
    print("💥 Candles error: $e");
    print(st);

    return Response.json(
      statusCode: 500,
      body: {
        'success': false,
        'error': 'Failed to fetch candles',
        'message': e.toString(),
        'timestamp': nowIso,
      },
    );
  }
}