// build/routes/last_price.dart
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
  try {
    // Optional query parameter ?pairs=EURUSD,USDJPY
    final pairsQuery = context.request.uri.queryParameters['pairs'];
    final pairs = (pairsQuery != null && pairsQuery.isNotEmpty)
        ? pairsQuery.split(',').map((p) => p.trim().toUpperCase()).toList()
        : ['EURUSD', 'USDJPY', 'GBPUSD']; // default pairs

    // Fetch last prices
    final results = <LastPrice>[];
    for (final pair in pairs) {
      final price = await DerivService.instance.getLastPrice(pair);
      final epoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      results.add(LastPrice(pair: pair, price: price, epoch: epoch));
    }

    return Response.json(
      body: results.map((e) => e.toJson()).toList(),
    );
  } catch (e, st) {
    // Log the error
    print('⚠ Failed to fetch last-prices: $e\n$st');
    return Response.json(
      statusCode: 500,
      body: {
        'error': 'Failed to fetch last prices',
        'details': e.toString(),
      },
    );
  }
}