// routes/last_prices.dart

import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';

/// ================= HELPERS =================

String _normalizePair(String pair) {
  var p = pair.toUpperCase().trim();

  p = p.replaceAll(RegExp(r'[^A-Z]'), '');

  while (p.startsWith('FRXFRX')) {
    p = p.substring(3);
  }

  if (!p.startsWith('FRX')) {
    p = 'FRX$p';
  }

  return p;
}

/// ================= MODEL =================

class LastPrice {
  final String pair;
  final double price;

  const LastPrice({
    required this.pair,
    required this.price,
  });

  Map<String, dynamic> toJson() {
    return {
      'pair': pair,
      'price': price,
    };
  }
}

/// ================= ROUTE =================

Future<Response> onRequest(RequestContext context) async {
  final nowIso = DateTime.now().toUtc().toIso8601String();

  print('');
  print('==========================================');
  print('⚡ /last-prices hit');
  print('🕒 $nowIso');
  print('==========================================');

  try {
    final deriv = DerivService.instance;

    if (!deriv.isConnected) {
      print('🔌 Connecting to Deriv...');
      await deriv.connect();
      print('✅ Connected');
    }

    final pairsQuery =
        context.request.uri.queryParameters['pairs'];

    final rawPairs =
        (pairsQuery != null && pairsQuery.isNotEmpty)
            ? pairsQuery
                .split(',')
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .toList()
            :<String>[
    'EURUSD',
    'GBPUSD',
    'USDJPY',
    'AUDUSD',
    'USDCAD',
    'USDCHF',
    'NZDUSD',
    'EURJPY',
    'GBPJPY',
    'AUDJPY',
    'EURGBP',
    'EURAUD',
    'GBPAUD',
    'GBPCHF',
    'EURCHF',
    'CADJPY',
    'CHFJPY',
    'AUDCAD',
    'AUDCHF',
    'AUDNZD',
    'NZDJPY',
    'NZDCAD',
    'NZDCHF',
    'GBPCAD',
    'EURNZD',
    'GBPNZD',
  ];

    final pairs =
        rawPairs.map(_normalizePair).toList();

    print('📊 Requested pairs: ${pairs.length}');
    print(pairs);

    final futures = pairs.map((pair) async {
      try {
        final price =
            await deriv.getLastPrice(pair);

        print('✅ $pair -> $price');

        return LastPrice(
          pair: pair,
          price: price,
        );
      } catch (e, st) {
        print('❌ FAILED $pair');
        print(e);
        print(st);

        return LastPrice(
          pair: pair,
          price: 0.0,
        );
      }
    });

    final results = await Future.wait(futures);

    final validPrices =
        results.where((e) => e.price > 0).length;

    print(
      '📈 Valid prices: $validPrices/${results.length}',
    );

    return Response.json(
      body: {
        "success": true,
        "count": results.length,
        "valid_prices": validPrices,
        "data": results
            .map((e) => e.toJson())
            .toList(),
        "timestamp": nowIso,
      },
    );
  } catch (e, st) {
    print('❌ /last-prices fatal error');
    print(e);
    print(st);

    return Response.json(
      statusCode: 500,
      body: {
        "success": false,
        "error": e.toString(),
        "timestamp":
            DateTime.now().toUtc().toIso8601String(),
      },
    );
  }
}