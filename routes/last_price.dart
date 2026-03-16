// build/routes/last_price.dart
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
  try {
    // Optional: query parameter ?pairs=EURUSD,USDJPY
    final pairsQuery = context.request.uri.queryParameters['pairs'];
    List<String> pairs;
    if (pairsQuery != null && pairsQuery.isNotEmpty) {
      pairs = pairsQuery.split(',');
    } else {
      // default pairs if none specified
      pairs = ['EURUSD', 'USDJPY', 'GBPUSD'];
    }

    // fetch last prices
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
    print('⚠ Failed to fetch last-prices: $e\n$st');
    return Response.json(
      statusCode: 500,
      body: {'error': 'Failed to fetch last prices', 'details': e.toString()},
    );
  }
}