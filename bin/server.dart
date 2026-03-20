import 'dart:io';
import 'package:dart_frog/dart_frog.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:shelf/shelf_io.dart' show serve;

// HTTP routes
import '../routes/balance.dart' as balance;
import '../routes/candles.dart' as candles;
import '../routes/last_prices.dart' as last_prices;
import '../routes/pairs.dart' as pairs;
import '../routes/trades.dart' as trades;
import '../routes/index.dart' as index;

// WebSocket route
import '../routes/signals.dart' as signals;

Future<void> main() async {
  // Create router
  final router = Router();

  // Attach HTTP routes
  router.mount('/balance', balance.router);
  router.mount('/candles', candles.router);
  router.mount('/last_prices', last_prices.router);
  router.mount('/pairs', pairs.router);
  router.mount('/trades', trades.router);
  router.mount('/', index.router);

  // Attach WebSocket route
  router.mount('/signals', signals.websocketHandler);

  // Pipeline with middleware (if any)
  final handler = Pipeline().addHandler(router);

  // Server config
  final ip = InternetAddress.anyIPv4;
  final port = int.tryParse(Platform.environment['PORT'] ?? '8080') ?? 8080;

  final server = await serve(handler, ip, port);
  print('🚀 Wisty Server running on http://${ip.address}:${server.port}');
}