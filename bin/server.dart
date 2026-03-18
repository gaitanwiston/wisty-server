import 'dart:io';
import 'package:dart_frog/dart_frog.dart';
import '../routes/signals.dart' as signals;

Future<void> main() async {
  // Manual Router
  final router = Router()
    ..all('/signals', signals.onRequest);

  // Pipeline ya middleware (remove logRequests kama hutaki shelf logs)
  final handler = Pipeline()
      //.addMiddleware(logRequests()) // uncomment ikiwa una shelf logs
      .addHandler(router);

  // Listen on all interfaces (0.0.0.0) na PORT env var au default 8080
  final ip = InternetAddress.anyIPv4;
  final port = int.tryParse(Platform.environment['PORT'] ?? '8080') ?? 8080;

  final server = await serve(handler, ip, port);

  print('🚀 Wisty Server running on ${ip.address}:${server.port}');
}