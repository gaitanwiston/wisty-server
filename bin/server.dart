import 'dart:io';
import 'package:dart_frog/dart_frog.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:shelf/shelf_io.dart' show serve;

// HTTP routes
import 'routes/balance.dart' as balance;
import 'routes/candles.dart' as candles;
import 'routes/last_prices.dart' as last_prices;
import 'routes/pairs.dart' as pairs;
import 'routes/trades.dart' as trades;
import 'routes/index_copy.dart' as index_copy;

// WebSocket route
import 'routes/signals.dart' as signals;

  final handler = const Pipeline()
      .addHandler(router);

  final ip = InternetAddress.anyIPv4;
  final port = int.tryParse(Platform.environment['PORT'] ?? '8080') ?? 8080;

  final server = await serve(handler, ip, port);
  print('🚀 Wisty Server running on http://${ip.address}:${server.port}');
}