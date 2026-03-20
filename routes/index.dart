import 'package:dart_frog/dart_frog.dart';

/// Handler for the /index_copy route
Future<Response> onRequest(RequestContext context) async {
  // Example JSON response
  return Response.json(
    body: {
      'status': 'success',
      'message': 'Welcome to Dart Frog!'
    },
  );
}