// routes/last_price.dart
import 'dart:convert';
import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';

/// Model for last price data
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

/// Route handler for GET /last-prices
Future<Response> onRequest(RequestContext context) async {
  final nowIso = DateTime.now().toIso8601String();
  print('⚡ /last-prices route hit at $nowIso');

  try {
    // Optional query parameter ?pairs=EURUSD,USDJPY
    final pairsQuery = context.request.uri.queryParameters['pairs'];
    final pairs = (pairsQuery != null && pairsQuery.isNotEmpty)
        ? pairsQuery.split(',').map((p) => p.trim().toUpperCase()).toList()
        : ['EURUSD', 'USDJPY', 'GBPUSD']; // default pairs

    final deriv = DerivService.instance;

    // Ensure WebSocket is connected
    if (!deriv.isConnected) {
      print("🔌 Connecting to Deriv WebSocket...");
      await deriv.connect();
      print("✅ Connected to Deriv WebSocket");
    }

    // Fetch last prices safely
    final results = <LastPrice>[];
    for (final pair in pairs) {
      try {
        final price = await deriv.getLastPrice(pair);
        final epoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        results.add(LastPrice(pair: pair, price: price, epoch: epoch));
      } catch (e) {
        print("⚠ Failed to fetch price for $pair: $e");
        results.add(LastPrice(pair: pair, price: 0.0, epoch: 0));
      }
    }

    return Response.json(
      body: results.map((e) => e.toJson()).toList(),
    );
  } catch (e, st) {
    // Log the error
    print('💥 /last-prices error: $e\n$st');
    return Response.json(
      statusCode: 500,
      body: {
        'error': 'Failed to fetch last prices',
        'details': e.toString(),
      },
    );
  }
}