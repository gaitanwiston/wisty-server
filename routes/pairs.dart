import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';

/// Simple in-memory cache (prevents spam calls)
List<String>? _cachedPairs;
DateTime? _lastFetch;
const Duration _cacheTime = Duration(seconds: 30);

Future<Response> onRequest(RequestContext context) async {
  final now = DateTime.now().toUtc();

  print("⚡ /pairs route hit at ${now.toIso8601String()}");

  final deriv = DerivService.instance;

  try {
    /// ================= CACHE LAYER =================
    if (_cachedPairs != null &&
        _lastFetch != null &&
        now.difference(_lastFetch!) < _cacheTime) {
      return Response.json(
        body: {
          "success": true,
          "source": "cache",
          "pairs": _cachedPairs,
          "count": _cachedPairs!.length,
          "timestamp": now.toIso8601String(),
        },
      );
    }

    /// ================= CONNECT ONLY ONCE =================
    if (!deriv.isConnected) {
      print("🔌 Initializing Deriv connection...");
      await deriv.connect();
      print("✅ Deriv ready");
    }

    /// ================= FETCH PAIRS =================
    final rawPairs = await deriv.getMarketPairs();

    /// ================= UPDATE CACHE =================
    _cachedPairs = rawPairs;
    _lastFetch = now;

    return Response.json(
      body: {
        "success": true,
        "source": "live",
        "pairs": rawPairs,
        "count": rawPairs.length,
        "timestamp": now.toIso8601String(),
      },
    );
  } catch (e, st) {
    print("💥 /pairs error: $e\n$st");

    return Response.json(
      statusCode: 500,
      body: {
        "success": false,
        "error": e.toString(),
        "timestamp": now.toIso8601String(),
      },
    );
  }
}