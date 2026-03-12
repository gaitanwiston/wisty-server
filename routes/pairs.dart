import 'package:dart_frog/dart_frog.dart';
import '../services/deriv_service.dart';

Future<Response> onRequest(RequestContext context) async {
  final deriv = DerivService.instance;

  try {
    final pairs = await deriv.getMarketPairs();

    // Sort alphabetically
    pairs.sort((a, b) => a.displayName.compareTo(b.displayName));

    final pairsJson = pairs.map((p) => {
      "symbol": p.symbol,
      "displayName": p.displayName,
      "type": p.type,
    }).toList();

    return Response.json(
      body: {
        "pairs": pairsJson,
        "timestamp": DateTime.now().toIso8601String(),
      },
    );
  } catch (e) {
    return Response.json(
      statusCode: 500,
      body: {
        "error": "Failed to fetch market pairs",
        "message": e.toString(),
      },
    );
  }
}