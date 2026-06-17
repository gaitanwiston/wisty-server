import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';

Future<Response> onRequest(RequestContext context) async {
  final deriv = DerivService.instance;
  final nowIso = DateTime.now().toUtc().toIso8601String();

  print("⚡ /balance hit → $nowIso");

  try {
    // ================= CONNECT =================
    if (!deriv.isConnected) {
      print("🔌 Connecting to Deriv...");
      await deriv.connect();
      print("✅ Connected");
    }

    // ================= FETCH BALANCE =================
    final balance = await deriv.getBalance();

    print("💰 Balance → $balance");

    return Response.json(
      body: {
        "success": true,
        "balance": balance,
        "timestamp": nowIso,
      },
    );
  } catch (e, st) {
    print("💥 /balance error → $e");
    print(st);

    return Response.json(
      statusCode: 500,
      body: {
        "success": false,
        "balance": 0.0,
        "error": e.toString(),
        "timestamp": nowIso,
      },
    );
  }
}