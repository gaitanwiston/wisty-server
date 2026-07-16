import 'package:dart_frog/dart_frog.dart';

import '../services/market_analysis_service.dart';
import '../services/trade_registry.dart';
import '../models/market_analysis_result.dart';

// =====================================================================
// route/candles.dart
// =====================================================================
//
// 🚨 MABADILIKO MAKUU YA USANIFU (kwa ombi la mtumiaji): awali route
// hii ilikuwa ikiomba candles MOJA KWA MOJA kutoka Deriv
// (deriv.getCandlesWithTF()) - candles hizo hazikuwa na lebo YOYOTE
// ya uchambuzi, na - MUHIMU ZAIDI - zingeweza kutofautiana na
// uchambuzi halisi unaotumika kuamua trade (route/trades.dart), kwa
// sababu zilikuwa zikisomwa kwa NYAKATI TOFAUTI kutoka VYANZO
// TOFAUTI vya WebSocket.
//
// Sasa candles + lebo za uchambuzi zinasomwa MOJA KWA MOJA kutoka
// 'MarketAnalysisService.instance.latestKeys' - CHANZO KIMOJA CHA
// UKWELI kile kile kinachotumika na route/trades.dart kuamua trade.
// Hii inahakikisha UI HAIWEZI kupokea candles/lebo zinazopingana na
// uamuzi halisi wa mfumo - "data haziwezi kutofautiana" kama
// ulivyoomba.
//
// ONGEZO JIPYA #2: kama alama ina TRADE ILIYO WAZI (imefunguliwa na
// route/trades.dart), sasa tunaonyesha SL/TP HALISI za trade hiyo
// (kutoka 'TradeRegistry' - hifadhi ya pamoja, angalia maelezo
// kwenye services/trade_registry.dart) - hizi ni tofauti na
// 'analysis.risk.stopLoss/takeProfit' (ambazo zinaendelea KUBADILIKA
// kila mzunguko mpya wa uchambuzi) - SL/TP za trade halisi zimekaa
// FIXED tangu wakati trade ilipofunguliwa, hadi itakapofungwa.
//
// ⚠️ KUMBUKA: kama 'MarketAnalysisService._latest' ipo tupu (server
// hii bado haijaita 'startPairs()'), route hii itarudisha data tupu
// kwa alama zote - angalia ONYO lile lile kwenye trades.dart.

// 🚨 FIX (bug halisi iliyoondolewa): '_normalizePair' ya awali
// ilikuwa ikilazimisha KILA alama kuanza na "FRX" - hii ni SAHIHI kwa
// forex TU, lakini ingeharibu KABISA majina ya synthetic indices
// (R_50, BOOM500, 1HZ100V, n.k.) na crypto (CRYBTCUSD) kwa
// kuziongezea "FRX" mbele yao kimakosa (ikitoa "FRXR_50",
// "FRXBOOM500" - majina yasiyokuwepo Deriv kabisa, yasingewahi
// kupatikana kwenye cache). Sasa hatuhitaji "normalize" ya namna hiyo
// hata kidogo - jina linalotumika ni lile lile UPPERCASE
// linalotumika na MarketAnalysisService kila mahali.
String _normalizeKey(String p) => p.trim().toUpperCase();

Future<Response> onRequest(RequestContext context) async {
  final now = DateTime.now().toUtc().toIso8601String();

  final rawPairs = context.request.uri.queryParameters['pairs'];

  final service = MarketAnalysisService.instance;

  Map<String, MarketAnalysisResult> selected;

  if (rawPairs == null || rawPairs.isEmpty) {
    // Bila 'pairs' kwenye query - rudisha ALAMA ZOTE zilizoshachambuliwa
    // hadi sasa.
    selected = service.latestKeys;
  } else {
    final wanted = rawPairs.split(',').map(_normalizeKey).toSet();

    selected = Map.fromEntries(
      service.latestKeys.entries.where((e) => wanted.contains(e.key)),
    );
  }

  final result = <String, dynamic>{};

  for (final entry in selected.entries) {
    final pair = entry.key;
    final analysis = entry.value;
    final ind = analysis.indicators;

    // ONGEZO JIPYA: trade iliyo wazi (kama ipo) kwa alama hii - kutoka
    // hifadhi ya PAMOJA na route/trades.dart (si tena data ya
    // 'private' isiyofikika).
    final activeTrade = TradeRegistry.instance.activeTradeFor(pair);

    result[pair] = {
      // Candles halisi zilizotumika kwenye uchambuzi huu (H1) - CHANZO
      // KIMOJA na uamuzi wa trade, si ombi jipya/tofauti kwa Deriv.
      "candles": analysis.candlesH1.map((c) {
        return {
          "time": DateTime.fromMillisecondsSinceEpoch(
            c.epoch * 1000,
            isUtc: true,
          ).toIso8601String(),
          "open": c.open,
          "high": c.high,
          "low": c.low,
          "close": c.close,
          "volume": c.volume,
        };
      }).toList(),

      // Lebo za uchambuzi - zile zile ZINAZOTUMIKA na route/trades.dart
      // kuamua kufungua trade au la (hakuna uwezekano wa "toleo
      // tofauti" kufika kwa UI).
      "direction": analysis.canBuy
          ? "BUY"
          : analysis.canSell
              ? "SELL"
              : "WAIT",

      // Bei za UCHAMBUZI WA SASA (zinabadilika kila mzunguko mpya) -
      // TOFAUTI na 'activeTrade' chini (ambazo zimekaa FIXED tangu
      // trade ilipofunguliwa).
      "entry": analysis.risk.entry,
      "stopLoss": analysis.risk.stopLoss,
      "takeProfit": analysis.risk.takeProfit,
      "lotSize": analysis.risk.lotSize,

      // ONGEZO JIPYA: SL/TP HALISI za trade iliyo wazi (kama ipo) -
      // null kama hakuna trade wazi kwa alama hii. UI inaweza kutumia
      // hizi kuchora mistari ya SL/TP HALISI kwenye chati, tofauti na
      // "entry/stopLoss/takeProfit" hapo juu (ambazo ni MAONI ya sasa
      // ya injini, si trade halisi).
      "activeTrade": activeTrade == null
          ? null
          : {
              "contractId": activeTrade.contractId,
              "direction": activeTrade.buy ? "BUY" : "SELL",
              "entry": activeTrade.entry,
              "stopLoss": activeTrade.sl,
              "takeProfit": activeTrade.tp,
              "currentPrice": activeTrade.current,
              "breakeven": activeTrade.breakeven,
              "openedAt": activeTrade.openedAt.toIso8601String(),
            },

      // ONGEZO JIPYA: "namba za uchambuzi" wazi (si tu 'indicators'
      // ya jumla) - mchanganuo wa kila kigezo, sambamba kabisa na
      // vile vinavyoonekana kwenye console debug log
      // (market_analysis_service.dart._log()).
      "analysisBreakdown": {
        "buyScore": ind["buy"],
        "sellScore": ind["sell"],
        "confidence": ind["confidence"],
        "trendAligned": ind["trendAligned"],
        "confluence": {
          "score": ind["confluence"],
          "confirmations": ind["confirmations"],
          "buyConfirmations": ind["buyConfirmations"],
          "sellConfirmations": ind["sellConfirmations"],
          "buyAligned": ind["buyAligned"],
          "sellAligned": ind["sellAligned"],
        },
        "ema": {
          "ema50": ind["ema50Last"],
          "ema200": ind["ema200Last"],
          "bullish": ind["emaBullish"],
          "bearish": ind["emaBearish"],
        },
        "rsi": {
          "value": ind["rsi"],
          "overbought": ind["rsiOverbought"],
          "oversold": ind["rsiOversold"],
        },
        "h4Structure": {
          "bosUp": ind["h4BosUp"],
          "bosDown": ind["h4BosDown"],
          "chochUp": ind["h4ChochUp"],
          "chochDown": ind["h4ChochDown"],
          "sweepHigh": ind["h4SweepHigh"],
          "sweepLow": ind["h4SweepLow"],
          "bullishOB": ind["h4BullishOB"],
          "bearishOB": ind["h4BearishOB"],
          "momentumUp": ind["h4MomentumUp"],
          "momentumDown": ind["h4MomentumDown"],
        },
        "priceAction": {
          "bullishEngulfing": ind["bullishEngulfing"],
          "bearishEngulfing": ind["bearishEngulfing"],
          "bullishPinBar": ind["bullishPinBar"],
          "bearishPinBar": ind["bearishPinBar"],
          "insideBar": ind["insideBar"],
          "doji": ind["doji"],
          "bullishRejection": ind["bullishRejection"],
          "bearishRejection": ind["bearishRejection"],
        },
        "smcExtra": {
          "premiumZone": ind["premiumZone"],
          "discountZone": ind["discountZone"],
          "bullishOrderFlow": ind["bullishOrderFlow"],
          "bearishOrderFlow": ind["bearishOrderFlow"],
          "bullishImbalance": ind["bullishImbalance"],
          "bearishImbalance": ind["bearishImbalance"],
          "inducement": ind["inducement"],
          "multiCandleConfirmation": ind["multiCandleConfirmation"],
          "sessionValid": ind["sessionValid"],
          "volatilityValid": ind["volatilityValid"],
          "fairValueGapsCount": ind["fairValueGapsCount"],
        },
      },

      // Data kamili ya ndani (kwa yeyote anayehitaji kila kitu bila
      // kuchuja) - imebaki kama ilivyokuwa.
      "indicators": ind,
      "conditionsMet": analysis.conditionsMet,
      "reasonsFailed": analysis.reasonsFailed,
    };
  }

  return Response.json(body: {
    "success": true,
    "count": result.length,
    "data": result,
    "timestamp": now,
  });
}