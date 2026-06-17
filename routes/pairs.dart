import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';

List<String>? _cachedPairs;
DateTime? _lastFetch;
const Duration _cacheTime = Duration(seconds: 30);

Future<Response> onRequest(RequestContext context) async {
  final now = DateTime.now().toUtc();

  print("⚡ /pairs hit at ${now.toIso8601String()}");

  try {
    // ================= CACHE FIRST =================
    if (_cachedPairs != null &&
        _lastFetch != null &&
        now.difference(_lastFetch!) < _cacheTime) {
      return Response.json(
        body: {
          "success": true,
          "source": "cache",
          "pairs": _cachedPairs,
          "count": _cachedPairs!.length,
        },
      );
    }

    final deriv = DerivService.instance;

    // ================= ENSURE SERVICE ONLY =================
    await deriv.ensureReady(); // 🔥 important fix (no reconnect spam here)

    // ================= GET PAIRS =================
    final rawPairs = await deriv.getMarketPairs();

    _cachedPairs = rawPairs;
    _lastFetch = now;

    return Response.json(
      body: {
        "success": true,
        "source": "live",
        "pairs": rawPairs,
        "count": rawPairs.length,
      },
    );
  } catch (e) {
    print("💥 /pairs error: $e");

    return Response.json(
      statusCode: 500,
      body: {
        "success": false,
        "error": e.toString(),
      },
    );
  }
}