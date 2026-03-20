// routes/candles.dart
import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';
import '../models/candle.dart';

Future<Response> onRequest(RequestContext context) async {
  final nowIso = DateTime.now().toUtc().toIso8601String();

  // Query params
  final pair =
      context.request.uri.queryParameters['pair']?.toUpperCase() ?? 'EURUSD';

  final timeframe =
      int.tryParse(context.request.uri.queryParameters['timeframe'] ?? '1') ?? 1;

  print("📊 /candles hit → $pair TF:$timeframe at $nowIso");

  try {
    /// Hakikisha connection ipo
    final deriv = DerivService.instance;
    if (!deriv.isConnected) {
      print("🔌 Connecting to Deriv...");
      await deriv.connect();
    }

    /// Fetch candles
    final candles =
        await deriv.getCandles(pair, timeframe: timeframe);

    if (candles.isEmpty) {
      return Response.json(
        statusCode: 404,
        body: {
          'success': false,
          'error': 'No candles found for $pair',
          'timestamp': nowIso,
        },
      );
    }

    /// Sort (ascending time)
    candles.sort((a, b) =>
        _parseEpoch(a.epoch).compareTo(_parseEpoch(b.epoch)));

    /// Convert to JSON
    final candleData = candles.map((c) {
      final epochSeconds = _parseEpoch(c.epoch);

      return {
        'time': DateTime.fromMillisecondsSinceEpoch(
                epochSeconds * 1000,
                isUtc: true)
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

/// Helper
int _parseEpoch(dynamic epoch) {
  if (epoch is int) return epoch;

  if (epoch is String) {
    try {
      return DateTime.parse(epoch).millisecondsSinceEpoch ~/ 1000;
    } catch (_) {
      return 0;
    }
  }

  return 0;
}