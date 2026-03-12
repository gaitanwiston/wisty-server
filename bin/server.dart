import 'dart:io';
import 'package:dart_frog/dart_frog.dart';
import 'package:wisty_server/routes/_middleware.dart';
import 'package:wisty_server/routes/_router.dart';

Future<void> main() async {
  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addHandler(router);

  final ip = InternetAddress.anyIPv4;
  final port = int.parse(Platform.environment['PORT'] ?? '8080');

  final server = await serve(handler, ip, port);

  print('Wisty Server running on port ${server.port}');
}