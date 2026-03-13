// routes/balance.dart
import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';

Future<Response> onRequest(RequestContext context) async {
  final deriv = DerivService.instance;

  print("⚡ /balance route hit at ${DateTime.now().toIso8601String()}");

  try {
    // Check DERIV_TOKEN
    final token = deriv.token;
    if (token == null || token.isEmpty) {
      print("❌ DERIV_TOKEN missing in environment!");
      return Response.json(
        statusCode: 500,
        body: {
          "balance": 0.0, // fallback balance
          "timestamp": DateTime.now().toIso8601String(),
          "error": "DERIV_TOKEN missing"
        },
      );
    }

    // Ensure websocket connection
    if (!deriv.isConnected) {
      print("🔌 Connecting to Deriv WebSocket...");
      await deriv.connect();
    }

    // Get balance
    final balance = await deriv.getBalance();
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
        "balance": 0.0,
        "timestamp": DateTime.now().toIso8601String(),
        "error": e.toString(),
      },
    );
  }
}