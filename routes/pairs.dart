import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';

/// Simple Pair model for JSON mapping
class MarketPair {
  final String symbol;
  final String displayName;
  final String type;

  MarketPair({
    required this.symbol,
    required this.displayName,
    required this.type,
  });
}

/// Route handler for GET /pairs
Future<Response> onRequest(RequestContext context) async {
  final nowIso = DateTime.now().toIso8601String();
  print("⚡ /pairs route hit at $nowIso");

  final deriv = DerivService.instance;

  try {
    // Ensure WebSocket connection
    if (!deriv.isConnected) {
      print("🔌 Connecting to Deriv WebSocket...");
      await deriv.connect();
      print("✅ Connected to Deriv WebSocket");
    }

    // Fetch market pairs (originally List<String>)
    final rawPairs = await deriv.getMarketPairs();

    // Convert to MarketPair objects
    final pairs = rawPairs.map((p) {
      // Example: p = "frxEURUSD"
      final symbol = p.toUpperCase();
      final displayName = symbol.replaceAll("FRX", ""); // strip prefix
      final type = "forex"; // default type, customize if needed
      return MarketPair(symbol: symbol, displayName: displayName, type: type);
    }).toList();

    // Sort alphabetically by displayName
    pairs.sort((a, b) => a.displayName.compareTo(b.displayName));

    // Map to JSON
    final pairsJson = pairs
        .map((p) => {
              "symbol": p.symbol,
              "displayName": p.displayName,
              "type": p.type,
            })
        .toList();

    return Response.json(
      body: {
        "pairs": pairsJson,
        "timestamp": nowIso,
      },
    );
  } catch (e, st) {
    print("💥 /pairs error: $e\n$st");

    return Response.json(
      statusCode: 500,
      body: {
        "error": "Failed to fetch market pairs",
        "details": e.toString(),
        "timestamp": nowIso,
      },
    );
  }
}