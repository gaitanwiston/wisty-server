import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';

Future<Response> onRequest(RequestContext context) async {
  final nowIso = DateTime.now().toUtc().toIso8601String();
  print("⚡ /pairs route hit at $nowIso");

  final deriv = DerivService.instance;

  try {
    if (!deriv.isConnected) {
      print("🔌 Connecting to Deriv WebSocket...");
      await deriv.connect();
      print("✅ Connected to Deriv WebSocket");
    }

    final rawPairs = await deriv.getMarketPairs();

    return Response.json(
      body: {
        "success": true,
        "pairs": rawPairs,
        "count": rawPairs.length,
        "timestamp": nowIso,
      },
    );
  } catch (e, st) {
    print("💥 /pairs error: $e\n$st");

    return Response.json(
      statusCode: 500,
      body: {
        "success": false,
        "error": e.toString(),
        "timestamp": nowIso,
      },
    );
  }
}