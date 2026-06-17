import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';
import '../models/candle.dart';

int _parseEpoch(dynamic epoch) {
  if (epoch is int) return epoch;
  if (epoch is double) return epoch.toInt();
  if (epoch is String) return int.tryParse(epoch) ?? 0;
  return 0;
}

String _normalizePair(String p) {
  String s = p.trim().replaceAll(' ', '');

  while (s.toUpperCase().startsWith('FRXFRX')) {
    s = s.substring(3);
  }

  if (!s.toUpperCase().startsWith('FRX')) {
    s = 'FRX$s';
  }

  return s;
}

Future<Response> onRequest(RequestContext context) async {
  final now = DateTime.now().toUtc().toIso8601String();

  final rawPairs = context.request.uri.queryParameters['pairs'];

  if (rawPairs == null || rawPairs.isEmpty) {
    return Response.json(body: {
      "success": false,
      "error": "pairs parameter required"
    });
  }

  final pairs = rawPairs.split(',').map(_normalizePair).toList();

  final deriv = DerivService.instance;

  if (!deriv.isConnected) {
    await deriv.connect();
  }

  final result = <String, dynamic>{};

  for (final pair in pairs) {
    await deriv.subscribe(pair);
    await Future.delayed(const Duration(milliseconds: 300));

    final candles = await deriv.getCandlesWithTF(pair);

    result[pair] = candles.map((c) {
      final epoch = _parseEpoch(c.epoch);

      return {
        "time": DateTime.fromMillisecondsSinceEpoch(
          epoch * 1000,
          isUtc: true,
        ).toIso8601String(),
        "open": c.open,
        "high": c.high,
        "low": c.low,
        "close": c.close,
        "volume": c.volume,
      };
    }).toList();
  }

  return Response.json(body: {
    "success": true,
    "count": pairs.length,
    "data": result,
    "timestamp": now
  });
}