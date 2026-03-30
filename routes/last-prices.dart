// routes/last_prices.dart
import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';

/// ================= HELPERS =================
/// Normalize pair (add FRX prefix if missing)
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

/// Safely parse candles epoch to int seconds
int _parseEpoch(dynamic epoch) {
  if (epoch is int) return epoch;
  if (epoch is double) return epoch.toInt();
  if (epoch is String) return int.tryParse(epoch) ?? 0;
  return 0;
}

/// ================= LAST PRICE MODEL =================
class LastPrice {
  final String pair;
  final double price;
  final int epoch;

  LastPrice({
    required this.pair,
    required this.price,
    required this.epoch,
  });

  Map<String, dynamic> toJson() => {
        'pair': pair,
        'price': price,
        'epoch': epoch,
      };
}

/// ================= ROUTE HANDLER =================
Future<Response> onRequest(RequestContext context) async {
  final nowIso = DateTime.now().toUtc().toIso8601String();
  print('⚡ /last-prices hit at $nowIso');

  try {
    final pairsQuery = context.request.uri.queryParameters['pairs'];

    final deriv = DerivService.instance;
    if (!deriv.isConnected) {
      print("🔌 Connecting to Deriv...");
      await deriv.connect();
      print("✅ Connected to Deriv");
    }

    // Parse pairs
    final pairs = (pairsQuery != null && pairsQuery.isNotEmpty)
        ? pairsQuery.split(',').map((p) => p.trim().toUpperCase()).toList()
        : ['EURUSD', 'USDJPY', 'GBPUSD'];

    final results = <LastPrice>[];

    for (final pair in pairs) {
      final normalized = _normalizePair(pair);
      try {
        final price = await deriv.getLastPrice(normalized);
        final candles = await deriv.getCandles(normalized);

        final epoch = (candles.isNotEmpty)
            ? _parseEpoch(candles.last.epoch)
            : DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

        results.add(
          LastPrice(pair: normalized, price: price, epoch: epoch),
        );
      } catch (e) {
        print("⚠ Failed price for $pair: $e");
        results.add(
          LastPrice(pair: normalized, price: 0.0, epoch: 0),
        );
      }
    }

    return Response.json(
      body: {
        "success": true,
        "count": results.length,
        "data": results.map((e) => e.toJson()).toList(),
        "timestamp": nowIso,
      },
    );
  } catch (e, st) {
    print('💥 /last_prices error: $e');
    print(st);

    return Response.json(
      statusCode: 500,
      body: {
        'success': false,
        'error': 'Failed to fetch last prices',
        'details': e.toString(),
        'timestamp': nowIso,
      },
    );
  }
}