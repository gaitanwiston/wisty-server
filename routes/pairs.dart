// routes/pairs.dart
import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';

/// ================= MARKET PAIR MODEL =================
class MarketPair {
  final String symbol;
  final String displayName;
  final String type;

  MarketPair({
    required this.symbol,
    required this.displayName,
    required this.type,
  });

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'displayName': displayName,
        'type': type,
      };
}

/// ================= PAIR NORMALIZER =================
String _normalizePair(String p) {
  p = p.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
  while (p.startsWith('FRXFRX')) {
    p = p.substring(3);
  }
  if (!p.startsWith('FRX')) {
    p = 'FRX$p';
  }
  return p;
}

/// ================= ROUTE HANDLER =================
Future<Response> onRequest(RequestContext context) async {
  final nowIso = DateTime.now().toUtc().toIso8601String();
  print("⚡ /pairs route hit at $nowIso");

  final deriv = DerivService.instance;

  try {
    // Ensure WebSocket connection
    if (!deriv.isConnected) {
      print("🔌 Connecting to Deriv WebSocket...");
      await deriv.connect();
      print("✅ Connected to Deriv WebSocket");
    }

    // Fetch raw market pairs from Deriv
    final rawPairs = await deriv.getMarketPairs();

    // Normalize and map to MarketPair model
    final pairs = rawPairs.map((p) {
      final symbol = _normalizePair(p);        // normalized FRX-prefixed symbol
      final displayName = symbol.replaceAll("FRX", ""); // remove prefix for display
      final type = "forex";                    // default type
      return MarketPair(symbol: symbol, displayName: displayName, type: type);
    }).toList();

    // Sort alphabetically by displayName
    pairs.sort((a, b) => a.displayName.compareTo(b.displayName));

    return Response.json(
      body: {
        "success": true,
        "pairs": pairs.map((p) => p.toJson()).toList(),
        "count": pairs.length,
        "timestamp": nowIso,
      },
    );
  } catch (e, st) {
    print("💥 /pairs error: $e\n$st");

    return Response.json(
      statusCode: 500,
      body: {
        "success": false,
        "error": "Failed to fetch market pairs",
        "details": e.toString(),
        "timestamp": nowIso,
      },
    );
  }
}