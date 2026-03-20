import 'dart:io';
import 'package:dart_frog/dart_frog.dart';

// HTTP routes
import '../routes/balance.dart' as balance;
import '../routes/candles.dart' as candles;
import '../routes/last_prices.dart' as last_prices;
import '../routes/pairs.dart' as pairs;
import '../routes/trades.dart' as trades;
import '../routes/index.dart' as index;

Future<void> main() async {
  // ⚡ Correct way: use Router() constructor
  final router = Router()
    ..mount('/balance', balance.router)
    ..mount('/candles', candles.router)
    ..mount('/last_prices', last_prices.router)
    ..mount('/pairs', pairs.router)
    ..mount('/trades', trades.router)
    ..mount('/', index.router);

  // Pipeline (middleware) wrapping
  final handler = Pipeline().addHandler(router);

  // Server config
  final ip = InternetAddress.anyIPv4;
  final port = int.tryParse(Platform.environment['PORT'] ?? '8080') ?? 8080;

  final server = await serve(handler, ip, port);
  print('🚀 Wisty HTTP Server running on http://${ip.address}:${server.port}');
}