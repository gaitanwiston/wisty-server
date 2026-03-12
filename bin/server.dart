import 'dart:io';
import 'package:dart_frog/dart_frog.dart';
import 'package:wisty_server/router.dart';

Future<void> main() async {
  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addHandler(router);

  final ip = InternetAddress.anyIPv4;
  final port = int.parse(Platform.environment['PORT'] ?? '8080');

  final server = await serve(handler, ip, port);

  print('Wisty Server running on port ${server.port}');
}