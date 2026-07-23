import 'dart:async';

import 'package:dart_frog/dart_frog.dart';

import '../services/deriv_service.dart';
import '../services/market_analysis_service.dart';

// =====================================================================
// routes/_middleware.dart - BOOTSTRAP YA SERVER 2
// =====================================================================
//
// ⚠️⚠️⚠️ TOLEO LA JARIBIO (DIAGNOSTIC TEST) - SI LA KUDUMU! ⚠️⚠️⚠️
// Sehemu ya 'startPairs()'/'startPeriodicAnalysis()' IMEZIMWA
// KIMAKUSUDI kwa muda - lengo ni kuunganisha na Deriv (connect +
// authorize) TU, BILA kusajili alama 92 - ili tuweze kupima kama
// '/balance' inafanya kazi kwenye muunganiko "safi" (bila msongamano
// wa candles/ohlc). MARA UCHUNGUZI HUU UKIISHA, RUDISHA TOLEO
// LILILOKUWA NA 'startPairs()' HAI (angalia sehemu
// iliyowekwa maoni chini) - vinginevyo '/candles' na '/trades'
// hazitafanya kazi (hazitakuwa na data ya uchambuzi kabisa).

bool _bootstrapped = false;

Handler middleware(Handler handler) {
  return (context) async {
    if (!_bootstrapped) {
      _bootstrapped = true;

      print(
        "🚀 BOOTSTRAP (JARIBIO - bila startPairs): Inaunganisha na "
        "Deriv TU, bila kusajili alama...",
      );

      unawaited(_bootstrap());
    }

    return handler(context);
  };
}

Future<void> _bootstrap() async {
  try {
    final deriv = DerivService.instance;

    await deriv.connect();

    // ⚠️ JARIBIO: sehemu hii YOTE imezimwa kimakusudi kwa muda -
    // angalia maelezo marefu hapo juu. RUDISHA baada ya uchunguzi:
    //
    // final pairs = await deriv.getMarketPairs();
    // print("📋 BOOTSTRAP: alama ${pairs.length} zimepatikana kutoka Deriv.");
    // final service = MarketAnalysisService.instance;
    // await service.startPairs(pairs);
    // service.startPeriodicAnalysis(pairs);

    print(
      "✅ BOOTSTRAP KAMILI (JARIBIO): muunganiko wa Deriv upo tayari "
      "(connect + authorize) - HAKUNA alama zilizosajiliwa kimakusudi. "
      "Sasa jaribu /balance mara moja.",
    );
  } catch (e, st) {
    print("❌ BOOTSTRAP IMESHINDWA: $e");
    print(st);

    _bootstrapped = false;
  }
}