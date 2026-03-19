import 'package:wisty_server/routes/trades.dart' as trades;
import 'package:wisty_server/routes/pairs.dart' as pairs;
import 'package:wisty_server/routes/last_prices.dart' as last_prices;
import 'package:wisty_server/routes/candles.dart' as candles;
import 'package:wisty_server/routes/balance.dart' as balance;
import 'package:dart_frog/dart_frog.dart';

// ---------------- HTTP Route Handlers ----------------
import '../routes/trades.dart' as trades;
import '../routes/pairs.dart' as pairs;
import '../routes/last_prices.dart' as last_prices; // underscore instead of hyphen
import '../routes/candles.dart' as candles;
import '../routes/balance.dart' as balance;

Future<void> main() async {
  // ---------------- Manual Router ----------------
  final router = Router()
    ..all('/trades', trades.onRequest)
    ..all('/pairs', pairs.onRequest)
    ..all('/last_prices', last_prices.onRequest) // corrected import
    ..all('/candles', candles.onRequest)
    ..all('/balance', balance.onRequest);

  // ---------------- Pipeline + Middleware ----------------
  final handler = Pipeline()
      // Uncomment logRequests() for debugging
      //.addMiddleware(logRequests())
      .addHandler(router);

  // ---------------- Server Configuration ----------------
  final ip = InternetAddress.anyIPv4;
  final port = int.tryParse(Platform.environment['PORT'] ?? '8080') ?? 8080;

  final server = await serve(handler, ip, port);

  print('🚀 Wisty HTTP API running on ${ip.address}:${server.port}');
}