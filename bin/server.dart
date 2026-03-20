import 'dart:io';
import 'package:dart_frog/dart_frog.dart';

// HTTP routes
import '../routes/balance.dart' as balance;
import '../routes/candles.dart' as candles;
import '../routes/last_prices.dart' as last_prices;
import '../routes/pairs.dart' as pairs;
import '../routes/trades.dart' as trades;
import '../routes/index.dart' as index;
import '../routes/signals.dart' as signals;

Future<void> main() async {
  final router = Router();

  // Mount routes with onRequest handlers
  router
    ..mount('/balance', balance.onRequest)
    ..mount('/candles', candles.onRequest)
    ..mount('/last_prices', last_prices.onRequest)
    ..mount('/pairs', pairs.onRequest)
    ..mount('/trades', trades.onRequest)
    ..mount('/signals', signals.onRequest);
    ..mount('/', index.onRequest);

  final handler = Pipeline().addHandler(router);

  final ip = InternetAddress.anyIPv4;
  final port = int.tryParse(Platform.environment['PORT'] ?? '8080') ?? 8080;

  final server = await serve(handler, ip, port);
  print('🚀 Wisty HTTP Server running on http://${ip.address}:${server.port}');
}