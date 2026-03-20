// routes/last_prices.dart
import 'dart:convert';
import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';

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

Future<Response> onRequest(RequestContext context) async {
  final nowIso = DateTime.now().toUtc().toIso8601String();
  print('⚡ /last_prices hit at $nowIso');

  try {
    final pairsQuery = context.request.uri.queryParameters['pairs'];

    final pairs = (pairsQuery != null && pairsQuery.isNotEmpty)
        ? pairsQuery
            .split(',')
            .map((p) => p.trim().toUpperCase())
            .toList()
        : ['EURUSD', 'USDJPY', 'GBPUSD'];

    final deriv = DerivService.instance;

    /// Ensure connection
    if (!deriv.isConnected) {
      print("🔌 Connecting to Deriv...");
      await deriv.connect();
    }

    final results = <LastPrice>[];

    for (final pair in pairs) {
      try {
        final price = await deriv.getLastPrice(pair);
        final epoch =
            DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

        results.add(
          LastPrice(pair: pair, price: price, epoch: epoch),
        );
      } catch (e) {
        print("⚠ Failed price for $pair: $e");

        results.add(
          LastPrice(pair: pair, price: 0.0, epoch: 0),
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