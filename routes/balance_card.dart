import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';

Future<Response> onRequest(RequestContext context) async {
  final deriv = DerivService.instance;

  try {
    // Ensure connected
    if (!deriv.isConnected) await deriv.connect();

    final balance = await deriv.getBalance();

    return Response.json(
      body: {
        "balance": balance,
        "timestamp": DateTime.now().toIso8601String(),
      },
    );
  } catch (e) {
    return Response.json(
      statusCode: 500,
      body: {
        "error": "Failed to fetch balance",
        "message": e.toString(),
      },
    );
  }
}