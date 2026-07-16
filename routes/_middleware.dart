import 'dart:async';

import 'package:dart_frog/dart_frog.dart';

import '../services/deriv_service.dart';
import '../services/market_analysis_service.dart';

// =====================================================================
// routes/_middleware.dart - BOOTSTRAP YA SERVER 2
// =====================================================================
//
// TATIZO LILILOSABABISHA "/candles" KURUDISHA "count":0: server hii
// (ya pili - risk management/execution) HAIJAWAHI kuita
// 'MarketAnalysisService.instance.startPairs([...])' kwenye
// muunganisho WAKE MWENYEWE wa Deriv - hivyo '_latest' (cache ya
// matokeo ya uchambuzi) ilibaki TUPU KABISA, na route zote
// zinazoitegemea (candles.dart, trades.dart) hazikuwa na kitu cha
// kurudisha.
//
// Dart Frog HAINA "main() ya kubuni" ya moja kwa moja kama mradi wa
// kawaida wa Dart (CLI inaizalisha upya kila 'dart_frog build') - njia
// SAHIHI na ya kudumu ya kuendesha "bootstrap" (uanzishaji wa mara
// moja) ni 'routes/_middleware.dart' - inaendeshwa KABLA ya route
// YOYOTE kwenye folda hii (na folda ndogo zake), kwa kila ombi - kwa
// hiyo tunatumia 'bool _bootstrapped' kuhakikisha logic halisi ya
// kuanzisha inafanyika MARA MOJA TU (kwenye ombi la kwanza
// litakalofika), si kila ombi.
//
// ⚠️ MUHIMU: ombi la KWANZA la "/candles" au "/trades" LITAFIKA
// mapema mno (bootstrap bado inaendelea kupakia data ya historia kwa
// alama zote) - subiri sekunde 10-30 baada ya server kuanza kabla ya
// kutarajia matokeo yenye maana. Fuatilia console - utaona
// "✅ Bootstrap kamili" ikichapishwa mara ikiisha.

bool _bootstrapped = false;

Handler middleware(Handler handler) {
  return (context) async {
    if (!_bootstrapped) {
      // Weka 'true' MARA MOJA (kabla ya 'await' yoyote) - inazuia
      // maombi mengi yanayofika kwa wakati mmoja (mf. mtandao wa
      // haraka wa health-checks) kuanzisha bootstrap zaidi ya mara
      // moja (race condition).
      _bootstrapped = true;

      print(
        "🚀 BOOTSTRAP: Inaanzisha uchambuzi wa live kwenye server 2...",
      );

      // Fire-and-forget kimakusudi - HATUSUBIRI (await) hapa, ili
      // ombi la kwanza la HTTP lisizuiliwe kwa muda mrefu (upakiaji wa
      // data ya alama zote unaweza kuchukua sekunde nyingi).
      unawaited(_bootstrap());
    }

    return handler(context);
  };
}

Future<void> _bootstrap() async {
  try {
    final deriv = DerivService.instance;

    await deriv.connect();

    final pairs = await deriv.getMarketPairs();

    print("📋 BOOTSTRAP: alama ${pairs.length} zimepatikana kutoka Deriv.");

    final service = MarketAnalysisService.instance;

    await service.startPairs(pairs);

    // Inalazimisha re-scan ya alama ZOTE kila dakika 5 - muhimu kwa
    // alama zisizo na ticks za mara kwa mara (mf. forex nje ya saa za
    // soko) kuendelea kuchambuliwa hata bila tick mpya ya moja kwa
    // moja - angalia maelezo marefu tuliyoyajadili kwenye server 1
    // kuhusu tatizo hili hili.
    service.startPeriodicAnalysis(pairs);

    print(
      "✅ BOOTSTRAP KAMILI: uchambuzi wa live umeanza kwa alama "
      "${pairs.length}. Data itaanza kuonekana kwenye /candles na "
      "/trades ndani ya sekunde chache hadi dakika kadhaa (kutegemea "
      "idadi ya alama).",
    );
  } catch (e, st) {
    print("❌ BOOTSTRAP IMESHINDWA: $e");
    print(st);

    // FIX (kuepuka "kufa kimya kabisa"): kama bootstrap ikishindwa
    // (mf. muunganisho wa Deriv umeshindikana wakati wa kuanza),
    // ruhusu jaribio jingine kwenye ombi linalofuata badala ya
    // kubaki "imefungwa" milele na _bootstrapped=true bila kufanikiwa
    // kamwe.
    _bootstrapped = false;
  }
}