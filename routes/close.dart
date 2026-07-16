import 'package:dart_frog/dart_frog.dart';

import '../services/deriv_service.dart';
import '../services/trade_registry.dart';

// =====================================================================
// routes/close.dart
// =====================================================================
//
// Njia rahisi zaidi (flat) badala ya
// 'routes/trades/[contractId]/close.dart' (nested dynamic route) -
// 'contractId' sasa inapitishwa kama:
//   1) query parameter: POST /close?contractId=xxx , AU
//   2) JSON body: POST /close  {"contractId": "xxx"}
// (query parameter ina kipaumbele ikiwa zote mbili zimetolewa).

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }

  String? contractId =
      context.request.uri.queryParameters['contractId'];

  if (contractId == null || contractId.isEmpty) {
    try {
      final body = await context.request.json();
      if (body is Map) {
        contractId = body['contractId']?.toString();
      }
    } catch (_) {
      // Body tupu/isiyo JSON - contractId inabaki null, itashughulikiwa
      // na ukaguzi hapa chini.
    }
  }

  if (contractId == null || contractId.isEmpty) {
    return Response.json(
      statusCode: 400,
      body: {"success": false, "error": "MISSING_CONTRACT_ID"},
    );
  }

  final trade = TradeRegistry.instance.trades[contractId];

  if (trade == null) {
    return Response.json(
      statusCode: 404,
      body: {"success": false, "error": "TRADE_NOT_FOUND"},
    );
  }

  if (trade.closed) {
    return Response.json(
      body: {"success": true, "status": "ALREADY_CLOSED"},
    );
  }

  try {
    trade.closed = true;

    await DerivService.instance.closeTradeById(contractId);

    TradeRegistry.instance.remove(contractId);

    print("🔴 TRADE CLOSED (manual, kutoka UI): $contractId");

    return Response.json(
      body: {
        "success": true,
        "status": "CLOSED",
        "contractId": contractId,
      },
    );
  } catch (e) {
    print("❌ CLOSE TRADE ERROR ($contractId): $e");

    return Response.json(
      statusCode: 500,
      body: {"success": false, "error": "$e"},
    );
  }
}