// routes/balance.dart
import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';

Future<Response> onRequest(RequestContext context) async {
  final deriv = DerivService.instance;
  final nowIso = DateTime.now().toUtc().toIso8601String();

  print("⚡ /balance route hit at $nowIso");

  try {
    // 1️⃣ Ensure WebSocket connection
    if (!deriv.isConnected) {
      print("🔌 Connecting to Deriv WebSocket...");
      try {
        await deriv.connect(); // uses default token if none provided
        print("✅ Connected to Deriv WebSocket");
      } catch (e) {
        print("💥 Failed to connect WebSocket: $e");
        return Response.json(
          statusCode: 500,
          body: {
            "success": false,
            "balance": 0.0,
            "timestamp": nowIso,
            "error": "Failed to connect to Deriv WebSocket: $e",
          },
        );
      }
    }

    // 2️⃣ Fetch balance (use cached first if available)
    double balance = deriv.cachedBalance;
    if (balance == 0.0) {
      print("⏳ Cached balance empty, fetching from Deriv...");
      try {
        // Wait max 5 seconds for balance to update
        balance = await deriv.getBalance(waitMs: 5000);
      } catch (e) {
        print("⚠ Failed to fetch balance: $e");
        balance = 0.0;
      }
    }

    print("💰 Returning balance: $balance");

    // 3️⃣ Return JSON to client
    return Response.json(
      body: {
        "success": true,
        "balance": balance,
        "timestamp": nowIso,
      },
    );
  } catch (e, stack) {
    print("💥 Balance API error: $e");
    print(stack);

    return Response.json(
      statusCode: 500,
      body: {
        "success": false,
        "balance": 0.0,
        "timestamp": nowIso,
        "error": e.toString(),
      },
    );
  }
}