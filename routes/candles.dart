import 'package:dart_frog/dart_frog.dart'; 
import '../services/deriv_service.dart';
import '../models/candle.dart';

Future<Response> onRequest(RequestContext context) async {
  // Pata query parameters, tumia defaults kama hazipo
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
    candles.sort((a, b) {
      int epochA = _parseEpoch(a.epoch);
      int epochB = _parseEpoch(b.epoch);
      return epochA.compareTo(epochB);
    });

    // Convert candles kwa format ya JSON
    final candleData = candles.map((c) {
      final epochSeconds = _parseEpoch(c.epoch);
      return {
        'time': DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000).toIso8601String(),
        'open': c.open,
        'high': c.high,
        'low': c.low,
        'close': c.close,
      };
    }).toList();

    return Response.json(
      body: {
        'pair': pair,
        'timeframe': timeframe,
        'candles': candleData,
      },
    );
  } catch (e, st) {
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

// Helper function to parse epoch safely
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