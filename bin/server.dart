import 'dart:io';
import 'package:dart_frog/dart_frog.dart';

// Import all route handlers
import '../routes/signals.dart' as signals;
import '../routes/trades.dart' as trades;
import '../routes/pairs.dart' as pairs;
import '../routes/last-prices.dart' as last_prices;
import '../routes/candles.dart' as candles;
import '../routes/balance.dart' as balance;

Future<void> main() async {
  // ---------------- Manual Router ----------------
  final router = Router()
    ..all('/signals', signals.onRequest)
    ..all('/trades', trades.onRequest)
    ..all('/pairs', pairs.onRequest)
    ..all('/last-prices', last_prices.onRequest)
    ..all('/candles', candles.onRequest)
    ..all('/balance', balance.onRequest);
  
  // ---------------- Pipeline + Middleware ----------------
  final handler = Pipeline()
      //.addMiddleware(logRequests()) // Uncomment kwa development
      .addHandler(router);

  // ---------------- Server Configuration ----------------
  final ip = InternetAddress.anyIPv4;
  final port = int.tryParse(Platform.environment['PORT'] ?? '8080') ?? 8080;

  final server = await serve(handler, ip, port);

  print('🚀 Wisty Server running on ${ip.address}:${server.port}');
}