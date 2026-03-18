import 'dart:io';
import 'package:dart_frog/dart_frog.dart';
import 'package:wisty_server/router.dart';

Future<void> main() async {
  // Pipeline ya middleware + router
  final handler = Pipeline()
      .addMiddleware(logRequests()) // logs requests to console
      .addHandler(router);

  // Listen on all interfaces (0.0.0.0) na PORT env var au default 8080
  final ip = InternetAddress.anyIPv4;
  final port = int.tryParse(Platform.environment['PORT'] ?? '8080') ?? 8080;

  final server = await serve(handler, ip, port);

  print('🚀 Wisty Server running on ${ip.address}:${server.port}');
}