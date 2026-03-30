import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';
import '../models/candle.dart';

/// ================= HELPERS =================
/// Safely parse epoch to seconds
int _parseEpoch(dynamic epoch) {
  if (epoch is int) return epoch;
  if (epoch is double) return epoch.toInt();
  if (epoch is String) return int.tryParse(epoch) ?? 0;
  return 0;
}

/// Normalize pair (FRX prefix) for Deriv API
String _normalizePair(String p) {
  p = p.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
  while (p.startsWith('FRXFRX')) {
    p = p.substring(3);
  }
  if (!p.startsWith('FRX')) {
    p = 'FRX$p';
  }
  return p;
}

/// ================= ROUTE HANDLER =================
Future<Response> onRequest(RequestContext context) async {
  final nowIso = DateTime.now().toUtc().toIso8601String();

  // Parse pair & timeframe
  final rawPair = context.request.uri.queryParameters['pair'] ?? 'EURUSD';
  final pair = _normalizePair(rawPair);
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

    if (!deriv.isConnected) {
      print("🔌 Connecting to Deriv WebSocket...");
      await deriv.connect();
      print("✅ Connected to Deriv");
    }

    // Fetch candles
    final candleList = await deriv.getCandlesWithTF(pair, timeframe: timeframe);

    // Map candles safely
    final candleData = candleList.map((c) {
      final epochSeconds = _parseEpoch(c.epoch);
      return {
        'time': DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true)
            .toIso8601String(),
        'open': c.open,
        'high': c.high,
        'low': c.low,
        'close': c.close,
        'volume': c.volume ?? 0, // ensure volume exists
      };
    }).toList();

    // Logging summary
    print("✅ Fetched ${candleData.length} candles for $pair");

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
    print("💥 /candles error for $pair: $e");
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