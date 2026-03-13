// routes/balance/index.dart
import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';

Future<Response> onRequest(RequestContext context) async {
  final deriv = DerivService.instance;

  print("⚡ /balance route hit at ${DateTime.now().toIso8601String()}");

  try {
    // Check if DERIV_TOKEN exists
    final token = deriv.token;
    if (token == null || token.isEmpty) {
      print("❌ DERIV_TOKEN missing in environment!");
      return Response.json(
        statusCode: 500,
        body: {
          "error": "DERIV_TOKEN missing",
          "message": "Please set DERIV_TOKEN in environment variables.",
        },
      );
    }

    // Ensure websocket connection
    if (!deriv.isConnected) {
      print("🔌 Connecting to Deriv WebSocket...");
      await deriv.connect();
    }

    // Fetch balance
    final balance = await deriv.getBalance();

    // Fallback if balance null
    final safeBalance = balance ?? 0.0;

    print("✅ Balance fetched: $safeBalance");

    return Response.json(
      body: {
        "balance": safeBalance,
        "timestamp": DateTime.now().toIso8601String(),
      },
    );
  } catch (e, stack) {
    print("💥 Balance API error: $e");
    print(stack);

    return Response.json(
      statusCode: 500,
      body: {
        "error": "Failed to fetch balance",
        "message": e.toString(),
      },
    );
  }
}