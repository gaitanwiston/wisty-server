import 'dart:io';
import 'package:dart_frog/dart_frog.dart';

// Import routes
import '../routes/balance.dart' as balance;
import '../routes/candles.dart' as candles;
import '../routes/last_prices.dart' as last_prices;
import '../routes/pairs.dart' as pairs;
import '../routes/trades.dart' as trades;
import '../routes/index.dart' as index;

Future<void> main() async {
  final router = Router();

  // Register routes
  router
    ..all('/balance', (context) => balance.onRequest(context))
    ..all('/candles', (context) => candles.onRequest(context))
    ..all('/last-prices', (context) => last_prices.onRequest(context)) // ✅ corrected dash
    ..all('/pairs', (context) => pairs.onRequest(context))
    ..all('/trades', (context) => trades.onRequest(context))
    ..all('/', (context) => index.onRequest(context));

  // Wrap router in a pipeline
  final handler = Pipeline().addHandler(router);

  // Listen on all IPv4 addresses and use PORT from environment or default 8080
  final ip = InternetAddress.anyIPv4;
  final port = int.tryParse(Platform.environment['PORT'] ?? '8080') ?? 8080;

  final server = await serve(handler, ip, port);
  print('🚀 Wisty HTTP Server running on http://${ip.address}:${server.port}');
}