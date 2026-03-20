// routes/balance.dart
import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';

Future<Response> onRequest(RequestContext context) async {
  final deriv = DerivService.instance;
  final nowIso = DateTime.now().toUtc().toIso8601String();

  print("⚡ /balance route hit at $nowIso");

  try {
    /// Ensure connection
    if (!deriv.isConnected) {
      print("🔌 Connecting to Deriv WebSocket...");
      await deriv.connect();
      print("✅ Connected to Deriv WebSocket");
    }

    /// Get balance
    final balance = await deriv.getBalance();
    final safeBalance = (balance ?? 0.0);

    print("💰 Balance fetched: $safeBalance");

    return Response.json(
      body: {
        "success": true,
        "balance": safeBalance,
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