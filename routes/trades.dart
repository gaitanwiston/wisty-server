import 'dart:async';
import 'dart:math';

import 'package:dart_frog/dart_frog.dart';

import '../services/deriv_service.dart';
import '../services/market_analysis_service.dart';
import '../services/trade_registry.dart';

// =====================================================================
// route/trades.dart - "MASTER OF PSYCHOLOGY"
// =====================================================================
//
// JUKUMU: hii ndiyo mahali pa MWISHO kabla pesa halisi haijatumika.
// Haiamini UI kipofu - inashirikiana na MarketAnalysisService (ambayo
// LAZIMA iendeshe live kwenye server hii YENYEWE - angalia ONYO chini)
// kuthibitisha SIGNAL kabla ya kuitekeleza, na inapanga 'stake' KWA
// KUZINGATIA balance halisi + umbali wa stop loss + confidence - SI
// lot fixed.
//
// ⚠️ ONYO LA UENDESHAJI (muhimu kabla ya kuanza kutumia faili hii):
// 'MarketAnalysisService.instance.latestFor(symbol)' inarudisha data
// TU kama server hii YENYEWE imeshaita 'startPairs([...])' (na kwa
// kupendekezwa 'startPeriodicAnalysis([...])' pia) kwenye muunganisho
// wake WENYEWE wa Deriv - kama vile server 1 (signals_server.dart)
// inavyofanya. Kama hujaweka bootstrap/main.dart inayofanya hivyo
// kwenye server hii, KILA ombi hapa litarudisha "NO_ANALYSIS" milele.

/// ================= GLOBAL BOT STATE =================
// FIX (usanifu bora): 'ActiveTrade'/'_activeTrades'/'_subscriptions'
// zilizokuwa hapa (za 'private', hazikuweza kufikiwa kutoka route
// nyingine kabisa - kwa mfano candles.dart) zimehamishiwa
// 'services/trade_registry.dart' - hifadhi MOJA ya pamoja
// inayoweza kufikiwa na route zote (candles.dart sasa inaweza kusoma
// SL/TP HALISI za trade zilizo wazi).
final Set<String> _processedSignals = {};

bool AUTO_TRADING_ENABLED = true;

// 🚨 FIX (bug hatari sana - "gate ya confidence ilikuwa IMEZIMWA kabisa
// bila kujulikana"): MIN_CONFIDENCE ilikuwa 0.72 (mizani 0-1). Lakini
// 'confidence' inayotumwa na server 1 (signals_server.dart, kutoka
// market_analysis_service.dart._calculateConfidence()) ni mizani 0-100
// (mf. 70.0 kwa 70%, si 0.70). Kulinganisha "70.0 < 0.72" ni FALSE KILA
// WAKATI kwa thamani yoyote halisi ya confidence - gate hii ilikuwa
// ikiruhusu HATA signal za confidence ya chini kabisa (mf. 5.0%) kupita
// bila kuzuiwa - hatari kubwa sana kwa pesa halisi.
double MIN_CONFIDENCE = 72.0; // MIZANI 0-100, SI 0-1!

int MAX_TRADES = 5;

/// ================= DAILY PROTECTION =================
double DAILY_PROFIT_TARGET_PERCENT = 10;
double DAILY_LOSS_LIMIT_PERCENT = 5;

double DAY_START_BALANCE = 0;
DateTime? LAST_RESET_DAY;

/// ================= EQUITY =================
double START_BALANCE = 0;
double CURRENT_BALANCE = 0;
double MAX_DRAWDOWN_PERCENT = 25;
int MAX_LOSS_STREAK = 3;
int lossStreak = 0;

bool KILL_SWITCH = false;

// ONGEZO JIPYA: 'multiplier' ya Multiplier contracts (angalia
// deriv_service.dart placeTrade()). ⚠️ 100 ni default ya kawaida TU -
// THIBITISHA thamani halali kwa kila alama (kupitia 'contracts_for',
// ambayo haijatengenezwa humu bado) kabla ya kutumia kwenye akaunti ya
// pesa halisi - baadhi ya alama/masoko yana ukomo tofauti kabisa.
int DEFAULT_MULTIPLIER = 100;

// ONGEZO JIPYA: kikomo cha juu cha 'stake' kama asilimia ya balance -
// ulinzi dhidi ya "position sizing explosion" (aina ile ile ya bug
// tuliyoipata na kuirekebisha kwenye backtest engine - stopDistance
// ndogo mno ikitoa stake kubwa isiyo ya busara).
double MAX_STAKE_PERCENT_OF_BALANCE = 10;

/// ================= DEBUG =================
void _trace(String title, dynamic msg) {
  print("\n[SERVER2-TRACE] ======================");
  print("[SERVER2-TRACE] $title");
  print("[SERVER2-TRACE] $msg");
  print("[SERVER2-TRACE] ======================\n");
}

/// ================= ENTRY =================
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method == HttpMethod.get) {
    // 🚨 FIX (bug halisi - "Open Trades" haikuwahi kuonyesha chochote):
    // awali GET hii ilikuwa ikirudisha TU muhtasari (idadi ya
    // trades) - HAIKUWA ikirudisha ORODHA YENYEWE ya trades zenye
    // maelezo (contractId, pair, entry, sl, tp, n.k.). UI upande wa
    // 'open_trades_panel.dart' (kupitia 'fetchActiveTrades()')
    // inatarajia 'data["trades"]' iwe ORODHA ya maelezo kamili ya kila
    // trade - bila hii, jopo la "Open Trades" lingeonyesha "Hakuna
    // trade" KILA WAKATI, hata kama kweli kuna trades wazi.
    final tradesList = TradeRegistry.instance.trades.values
        .where((t) => !t.closed)
        .map((t) => {
              "contractId": t.contractId,
              "pair": t.pair,
              "buy": t.buy,
              "entryPrice": t.entry,
              "sl": t.sl,
              "tp": t.tp,
              "current": t.current,
              "breakeven": t.breakeven,
              "status": "OPEN",
              "openedAt": t.openedAt.toIso8601String(),
            })
        .toList();

    return Response.json(
      body: {
        "success": true,
        "trades": tradesList,
        "active_trades": TradeRegistry.instance.count,
        "cache_size": MarketAnalysisService.instance.latestKeys.length,
        "kill_switch": KILL_SWITCH,
        "auto_trading_enabled": AUTO_TRADING_ENABLED,
        "current_balance": CURRENT_BALANCE,
      },
    );
  }

  if (context.request.method == HttpMethod.post) {
    final body = await context.request.json();
    _trace("RAW UI PAYLOAD", body);
    return _handleSignal(body as Map<String, dynamic>);
  }

  return Response(statusCode: 405);
}

/// ================= HANDLE SIGNAL =================
Future<Response> _handleSignal(Map<String, dynamic> json) async {
  try {
    if (KILL_SWITCH || !AUTO_TRADING_ENABLED) {
      return Response.json(body: {"status": "BOT_DISABLED"});
    }

    _trace("STEP 1 - RAW INPUT", json);

    if (json['type'] != 'signal') {
      return Response.json(
        statusCode: 400,
        body: {"error": "INVALID_PAYLOAD"},
      );
    }

    final symbolRaw = json['symbol']?.toString() ?? '';
    final direction = json['direction']?.toString() ?? '';
    final confidence = (json['confidence'] as num?)?.toDouble() ?? 0.0;

    final timestamp = json['timestamp']?.toString().isNotEmpty == true
        ? json['timestamp'].toString()
        : DateTime.now().millisecondsSinceEpoch.toString();

    // FIX (uwiano na server 1): jina hili ni la UPPERCASE tu - ni sahihi
    // kwa MATUMIZI YA NDANI (funguo za map, kuoanisha na
    // MarketAnalysisService._latest ambayo NAYO inatumia UPPERCASE
    // kila mahali) - SI kwa kutuma kwa Deriv moja kwa moja (angalia
    // 'derivSymbol' chini kabla ya placeTrade()).
    final symbol = _normalizeSymbol(symbolRaw);
    final signalId = "${symbol}_$timestamp";

    _trace("STEP 2 - NORMALIZED DATA", {
      "raw": symbolRaw,
      "symbol": symbol,
      "direction": direction,
      "confidence": confidence,
      "signalId": signalId,
    });

    print("\n📥 SIGNAL → $symbol | $direction | $confidence");

    if (_processedSignals.contains(signalId)) {
      _trace("DECISION", "DUPLICATE");
      return Response.json(body: {"status": "DUPLICATE"});
    }
    _processedSignals.add(signalId);

    if (confidence < MIN_CONFIDENCE) {
      _trace(
        "DECISION",
        "LOW CONFIDENCE ($confidence < $MIN_CONFIDENCE)",
      );
      return Response.json(body: {"status": "LOW_CONFIDENCE"});
    }

    if (TradeRegistry.instance.count >= MAX_TRADES) {
      _trace("DECISION", "MAX TRADES");
      return Response.json(body: {"status": "MAX_TRADES"});
    }

    // ONGEZO JIPYA: usifungue trade ya PILI kwenye alama ile ile
    // ambayo tayari ina trade wazi - epuka "double exposure"
    // isiyokusudiwa kwenye alama moja.
    if (TradeRegistry.instance.hasOpenTrade(symbol)) {
      _trace("DECISION", "ALREADY OPEN FOR $symbol");
      return Response.json(body: {"status": "ALREADY_OPEN_FOR_SYMBOL"});
    }

    CURRENT_BALANCE = await _getBalance();

    if (START_BALANCE == 0) START_BALANCE = CURRENT_BALANCE;

    _checkEquityProtection();
    _checkDailyLimits();

    if (KILL_SWITCH) {
      _trace("DECISION", "KILL SWITCH");
      return Response.json(body: {"status": "KILL_SWITCH"});
    }

    /// ================= ANALYSIS ("PSYCHOLOGY") =================
    // Hapa ndipo "master of psychology" inatokea kwa uhalisia: SIYO
    // kuamini kipofu 'direction'/'confidence' zilizotumwa na UI (ambazo
    // zinaweza kuwa na SEKUNDE kadhaa za "umri" kwa wakati zinafika
    // hapa) - badala yake tunathibitisha dhidi ya UCHAMBUZI WA SASA WA
    // SERVER HII YENYEWE.
    final service = MarketAnalysisService.instance;

    _trace("STEP 3 - CACHE STATE (idadi ya alama)",
        service.latestKeys.length);

    final analysis = service.latestFor(symbol);

    _trace("STEP 4 - ANALYSIS EXISTS", analysis != null);

    if (analysis == null) {
      _trace(
        "DECISION",
        "NO ANALYSIS FOUND - je 'startPairs()' imeitwa kwenye server "
        "hii kwa alama hii? Angalia ONYO mwanzoni mwa faili hii.",
      );
      return Response.json(body: {"status": "NO_ANALYSIS"});
    }

    // FIX (bug halisi ya compile): 'isValidTrade' HAIPO kwenye
    // MarketAnalysisResult (angalia models/market_analysis_result.dart)
    // - hii ilikuwa ikisababisha hitilafu ya compile kabisa. 'canBuy ||
    // canSell' ni sawa kimantiki (ndivyo 'isValidTrade' ilivyokuwa
    // ikihesabiwa kwenye faili nyingine za mfumo huu).
    final analysisIsValid = analysis.canBuy || analysis.canSell;

    _trace("ANALYSIS DETAILS", analysis.indicators);
    _trace("CAN BUY", analysis.canBuy);
    _trace("CAN SELL", analysis.canSell);
    _trace("IS VALID (canBuy||canSell)", analysisIsValid);

    if (!analysisIsValid) {
      _trace("DECISION", "INVALID ANALYSIS (server hii inasema WAIT)");
      return Response.json(body: {"status": "INVALID_ANALYSIS"});
    }

    final isBuy = direction.toUpperCase() == "BUY";

    // ONGEZO JIPYA (usalama muhimu - "psychology" halisi): kama UI
    // inasema BUY lakini uchambuzi WA SASA wa server hii unasema SELL
    // (au haujakubali BUY hata kidogo), hii ni ishara wazi kwamba
    // signal imepitwa na wakati (stale) tangu ilipotumwa na UI - KATAA
    // trade badala ya kuiamini kipofu.
    if (isBuy && !analysis.canBuy) {
      _trace(
        "DECISION",
        "MISMATCH - UI inasema BUY, uchambuzi wa SASA hausemi hivyo",
      );
      return Response.json(body: {"status": "STALE_SIGNAL_MISMATCH"});
    }

    if (!isBuy && !analysis.canSell) {
      _trace(
        "DECISION",
        "MISMATCH - UI inasema SELL, uchambuzi wa SASA hausemi hivyo",
      );
      return Response.json(body: {"status": "STALE_SIGNAL_MISMATCH"});
    }

    _trace("DECISION", "APPROVED");

    /// ================= TRADE =================
    final deriv = DerivService.instance;

    // FIX (chanzo kimoja cha ukweli): tunatumia bei za UCHAMBUZI WA
    // SASA wa server hii (analysis.risk) - SI zile zilizotumwa na UI
    // kwenye JSON (ambazo zinaweza kuwa stale kidogo kuliko cache ya
    // ndani ya server hii).
    final entry = analysis.risk.entry;
    final sl = analysis.risk.stopLoss;
    final tp = analysis.risk.takeProfit;

    if (entry <= 0 || sl <= 0 || tp <= 0) {
      _trace("DECISION", "INVALID RISK LEVELS (entry/sl/tp)");
      return Response.json(body: {"status": "INVALID_RISK_LEVELS"});
    }

    // 🚨 FIX (bug hatari ya casing - kwa UTEKELEZAJI WA PESA HALISI,
    // si data tu): 'symbol' ni UPPERCASE (jina la ndani) - Deriv
    // inahitaji jina HALISI (herufi mchanganyiko kiasili, mf.
    // "frxEURUSD") kwenye ombi la trade halisi. Bila hii, FRX/CRY/
    // stpRNG zisingefanya kazi (bug ile ile tuliyoipata kwa
    // ticks_history, sasa ingeathiri PESA HALISI).
    final derivSymbol = deriv.resolveOriginalCasing(symbol);

    // FIX (usalama mkubwa - "position sizing" ya kweli, si fixed wala
    // "confidence tiers" bila kuzingatia stopDistance): angalia
    // _calculateStake() chini - inatumia balance HALISI + umbali wa
    // stop loss + confidence, ikiwa na kikomo cha usalama dhidi ya
    // "explosion".
    final stake = _calculateStake(
      confidence: confidence,
      balance: CURRENT_BALANCE,
      entry: entry,
      stopLoss: sl,
      multiplier: DEFAULT_MULTIPLIER,
    );

    _trace("TRADE EXECUTION", {
      "symbol (internal)": symbol,
      "symbol (Deriv halisi)": derivSymbol,
      "type": isBuy ? "BUY" : "SELL",
      "entry": entry,
      "sl": sl,
      "tp": tp,
      "stake": stake,
      "multiplier": DEFAULT_MULTIPLIER,
      "balance": CURRENT_BALANCE,
    });

    // 🚨 MABADILIKO MAKUBWA (usanifu safi zaidi - kwa ombi la
    // mtumiaji): placeTrade() sasa ni JARIBIO MOJA TU (single-shot),
    // ikirudisha PlaceTradeResult yenye taarifa KAMILI za hitilafu
    // (si contractId==null tu). trades.dart (HII HAPA) NDIYO
    // ANAYEAMUA sasa jinsi ya kujaribu tena (stake mpya, muda mpya) -
    // SI deriv_service.dart. Angalia _placeTradeWithRetries() chini -
    // ndipo mantiki yote ya "jaribu tena" ilipo sasa, ikiheshimu
    // MAX_STAKE_PERCENT_OF_BALANCE na MIN_STAKE muda wote.
    final result = await _placeTradeWithRetries(
      derivSymbol: derivSymbol,
      symbol: symbol,
      isBuy: isBuy,
      initialStake: stake,
      balance: CURRENT_BALANCE,
    );

    if (!result.success) {
      print(
        "\n"
        "❌❌❌ TRADE IMEKATALIWA NA DERIV ❌❌❌\n"
        "   Alama       : $symbol (Deriv: $derivSymbol)\n"
        "   Mwelekeo    : ${isBuy ? "BUY (CALL)" : "SELL (PUT)"}\n"
        "   Stake iliyojaribiwa (ya mwisho) : \$${result.finalStake.toStringAsFixed(2)}\n"
        "   Sababu HALISI : ${result.error?.message}\n"
        "   (code=${result.error?.code}, subcode=${result.error?.subcode})\n"
        "=====================================\n",
      );
      _trace("ERROR", "TRADE FAILED: ${result.error}");
      return Response.json(body: {
        "error": "TRADE_FAILED",
        "reason": result.error?.message,
      });
    }

    final contractId = result.contractId!;
    final finalStake = result.finalStake;

    _trace("SUCCESS", contractId);

    final trade = ActiveTrade(
      contractId: contractId,
      pair: symbol,
      buy: isBuy,
      entry: entry,
      sl: sl,
      tp: tp,
      // KUMBUKA: 'stake'/'multiplier' zimehifadhiwa kwenye ActiveTrade
      // kwa uwiano wa API (na endapo siku moja kutahamia Multipliers
      // tena) - kwa CALL/PUT ya sasa, SL/TP zinasimamiwa NA
      // kutekelezwa NA server hii YENYEWE (_subscribeToTrade() chini),
      // si na Deriv.
      stake: finalStake,
      multiplier: DEFAULT_MULTIPLIER,
    );

    TradeRegistry.instance.register(trade);
    _subscribeToTrade(trade);

    // 🚨 ONGEZO JIPYA (kwa ombi la mtumiaji): print WAZI ya uthibitisho
    // baada ya trade kukubaliwa - inaonyesha KWA UWAZI: imekubaliwa,
    // stake kiasi gani, na SL/TP ZILIZOWEKWA (ambazo server hii
    // YENYEWE itasimamia/itatekeleza, kwa kuwa CALL/PUT haina SL/TP
    // asili upande wa Deriv - angalia maelezo kwenye deriv_service.dart).
    print(
      "\n"
      "✅✅✅ TRADE IMEKUBALIWA NA DERIV ✅✅✅\n"
      "   Contract ID : $contractId\n"
      "   Alama       : $symbol (Deriv: $derivSymbol)\n"
      "   Mwelekeo    : ${isBuy ? "BUY (CALL)" : "SELL (PUT)"}\n"
      "   Stake (ya mwisho, baada ya marekebisho yoyote) : \$${finalStake.toStringAsFixed(2)}\n"
      "   Entry       : $entry\n"
      "   SL iliyowekwa (server hii itasimamia) : $sl\n"
      "   TP iliyowekwa (server hii itasimamia) : $tp\n"
      "   Balance baada ya trade                : \$${CURRENT_BALANCE.toStringAsFixed(2)}\n"
      "=====================================\n",
    );

    return Response.json(body: {
      "status": "EXECUTED",
      "contractId": contractId,
      "symbol": symbol,
      "stake": finalStake,
      "sl": sl,
      "tp": tp,
      "balance": CURRENT_BALANCE,
    });
  } catch (e, st) {
    _trace("ERROR", e);
    _trace("STACK", st);
    return Response.json(statusCode: 500, body: {"error": "$e"});
  }
}

/// ================= BALANCE =================
Future<double> _getBalance() async {
  final deriv = DerivService.instance;
  if (!deriv.isConnected) await deriv.connect();
  return deriv.getBalance();
}

/// ================= EQUITY =================
void _checkEquityProtection() {
  if (START_BALANCE == 0) return;

  final dd = ((START_BALANCE - CURRENT_BALANCE) / START_BALANCE) * 100;

  if (dd >= MAX_DRAWDOWN_PERCENT) {
    KILL_SWITCH = true;
    AUTO_TRADING_ENABLED = false;
    _trace("RISK", "DRAWDOWN $dd%");
  }
}

void _checkDailyLimits() {
  // FIX (uwiano na mfumo mzima): tumia UTC, si saa za ndani za server
  // - inaepuka "siku" kubadilika kwa nyakati tofauti kutegemea eneo la
  // server, sambamba na mkataba wa saa uliotumika kila mahali pengine
  // kwenye mfumo huu.
  final now = DateTime.now().toUtc();

  if (LAST_RESET_DAY == null ||
      LAST_RESET_DAY!.day != now.day ||
      LAST_RESET_DAY!.month != now.month ||
      LAST_RESET_DAY!.year != now.year) {
    LAST_RESET_DAY = now;
    DAY_START_BALANCE = CURRENT_BALANCE;
  }

  final pnl = DAY_START_BALANCE == 0
      ? 0
      : ((CURRENT_BALANCE - DAY_START_BALANCE) / DAY_START_BALANCE) * 100;

  _trace("PNL", pnl);

  if (pnl >= DAILY_PROFIT_TARGET_PERCENT ||
      pnl <= -DAILY_LOSS_LIMIT_PERCENT) {
    KILL_SWITCH = true;
    AUTO_TRADING_ENABLED = false;
    _trace("RISK", "DAILY LIMIT HIT");
  }
}

/// ================= SUBSCRIBE =================
// MABADILIKO MAKUBWA (baada ya kuhamia CALL/PUT - Options API):
// CALL/PUT HAINA 'contract_update'/'limit_order' asili kabisa (hizo
// ni dhana za Multiplier contracts TU, ambazo hazipatikani kwenye
// akaunti hii). Kwa hiyo SL/TP HAZIWEZI "kubadilishwa" upande wa
// Deriv - ufuatiliaji wa NDANI (humu humu) NDIYO utaratibu MKUU (SI
// safu ya pili tena) wa kuamua ni lini trade inafungwa - kwa
// kutumia 'sellContract()' (kuuza contract mapema, kabla ya muda
// wake wa asili "wavu wa usalama" kuisha).
//
// Kwa ombi la mtumiaji - "fuatilia soko ili kuajust TP kama bado hali
// ni nzuri": kila muda fulani (throttled), tunachukua UCHAMBUZI MPYA
// KABISA wa alama hii, na kama bado unaonyesha mwelekeo ULE ULE NA TP
// mpya iliyohesabiwa ni BORA zaidi - TUNAPANUA TP (ndani TU - hakuna
// haja ya "kuambia" Deriv, kwa kuwa CALL/PUT haina TP ya asili
// kuibadilisha).
const Duration _tpCheckThrottle = Duration(seconds: 45);

void _subscribeToTrade(ActiveTrade trade) {
  final deriv = DerivService.instance;

  final sub = deriv.subscribeContract(trade.contractId, (tick) async {
    if (trade.closed) return;

    final price = (tick['price'] as num? ?? 0).toDouble();
    trade.current = price;

    final risk = (trade.entry - trade.sl).abs();
    if (risk == 0) return;

    final rr = trade.buy
        ? (price - trade.entry) / risk
        : (trade.entry - price) / risk;

    if (!trade.breakeven && rr >= 1) {
      // FIX: sasisha SL ya NDANI TU - hakuna 'contract_update' kwa
      // CALL/PUT (haipo). Ufuatiliaji huu wa ndani (tpHit/slHit hapa
      // chini) NDIYO utakaogundua bei ikigusa SL hii mpya na
      // kuamuru 'sellContract()'.
      trade.sl = trade.entry;
      trade.breakeven = true;

      _trace("BREAKEVEN (SL ya ndani imesogezwa hadi entry)", trade.contractId);
    }

    // TP extension - throttled (si kila tick).
    final now = DateTime.now().toUtc();
    final dueForCheck = trade.lastTpCheck == null ||
        now.difference(trade.lastTpCheck!) >= _tpCheckThrottle;

    if (dueForCheck && rr > 0) {
      trade.lastTpCheck = now;
      await _maybeExtendTakeProfit(trade);
    }

    final tpHit = trade.buy ? price >= trade.tp : price <= trade.tp;
    final slHit = trade.buy ? price <= trade.sl : price >= trade.sl;

    if (tpHit || slHit) {
      await _closeTrade(trade, reason: tpHit ? "TP" : "SL");
    }
  });

  TradeRegistry.instance.subscriptions[trade.contractId] = sub;
}

/// ================= TP EXTENSION (ONGEZO JIPYA) =================
/// Kama uchambuzi WA SASA (fresh) bado unaonyesha mwelekeo ULE ULE
/// wenye nguvu, na TP mpya iliyohesabiwa (kwa mantiki ya SL/TP
/// structure-aware) ni BORA zaidi kuliko TP ya sasa ya trade hii -
/// panua TP YA NDANI (hakuna 'contract_update' ya Deriv kwa CALL/PUT
/// - ufuatiliaji wetu wa ndani NDIYO utakaotambua TP mpya).
///
/// 🔒 DHAMANA MUHIMU (kwa ombi la mtumiaji): TP HAIWEZI KAMWE
/// KUPUNGUA (kurudi karibu na entry) - INAWEZA TU KUONGEZEKA (kuenda
/// mbali zaidi, faida zaidi). Hii ni "ratchet" ya upande MMOJA TU -
/// mara TP ikiongezwa, HAIREJEI NYUMA kamwe, hata kama uchambuzi wa
/// baadaye ungependekeza TP ndogo zaidi. Angalia '_isTpImprovement()'
/// hapa chini - ndiyo eneo PEKEE linaloamua kama kubadilisha TP au
/// la, na masharti yake ni WAZI: BUY inahitaji freshTp KUBWA ZAIDI ya
/// tp ya sasa; SELL inahitaji freshTp NDOGO ZAIDI ya tp ya sasa -
/// HAKUNA njia nyingine ya kubadilisha 'trade.tp' popote kwenye
/// mfumo huu.
Future<void> _maybeExtendTakeProfit(ActiveTrade trade) async {
  try {
    final freshAnalysis =
        MarketAnalysisService.instance.latestFor(trade.pair);

    if (freshAnalysis == null) return;

    // Soko bado ni "zuri" kwa mwelekeo huu HALISI - uchambuzi mpya
    // bado unathibitisha mwelekeo ULE ULE wa trade hii.
    final stillGood =
        trade.buy ? freshAnalysis.canBuy : freshAnalysis.canSell;

    if (!stillGood) return;

    final freshTp = freshAnalysis.risk.takeProfit;

    // FIX (usalama wa ziada): kataa thamani za TP zisizo halali
    // (sifuri/hasi) kabla ya kuzifikiria kabisa - ulinzi dhidi ya
    // data mbovu ya uchambuzi kuharibu TP nzuri iliyopo tayari.
    if (freshTp <= 0) return;

    if (!_isTpImprovement(trade, freshTp)) return;

    final oldTp = trade.tp;
    trade.tp = freshTp;

    _trace(
      "TP EXTENDED (soko bado ni zuri - NDANI TU, CALL/PUT haina TP ya asili)",
      "${trade.pair} ${trade.contractId}: $oldTp -> $freshTp "
      "(TP HAITAWAHI kupungua chini ya thamani hii tena)",
    );
  } catch (e) {
    _trace("TP EXTENSION ERROR", "${trade.contractId}: $e");
  }
}

/// 🔒 Kazi PEKEE inayoamua kama TP mpya ni "bora zaidi" - ndiyo
/// "geti" pekee linaloruhusu 'trade.tp' kubadilika. Kanuni ni WAZI na
/// ya upande MMOJA TU (ratchet):
///   - BUY: TP mpya lazima iwe KUBWA ZAIDI (mbali zaidi juu) kuliko
///     TP ya sasa - vinginevyo HAPANA.
///   - SELL: TP mpya lazima iwe NDOGO ZAIDI (mbali zaidi chini)
///     kuliko TP ya sasa - vinginevyo HAPANA.
/// Kwa njia hii, TP HAIWEZI KAMWE kusogea karibu na entry tena mara
/// ikishasogea mbali - inaweza TU kuendelea kusogea mbali zaidi.
bool _isTpImprovement(ActiveTrade trade, double freshTp) {
  return trade.buy ? freshTp > trade.tp : freshTp < trade.tp;
}

/// ================= CLOSE =================
// FIX: sasa inaita 'sellContract()' HALISI (kupitia
// deriv.closeTradeById(), ambayo NAYO sasa imerekebishwa itumie
// 'sell', si 'forget' - angalia maelezo marefu upande wa
// deriv_service.dart) - kwa hiyo trade INAFUNGWA KWELI kwenye Deriv
// sasa, si "kuachwa kufuatiliwa" tu kama ilivyokuwa awali.
Future<void> _closeTrade(ActiveTrade trade, {required String reason}) async {
  if (trade.closed) return;

  // 🚨 FIX (bug halisi): awali 'trade.closed=true' ilikuwa ikiwekwa
  // KABLA ya kujaribu kufunga, na trade ilikuwa ikiondolewa kwenye
  // TradeRegistry HATA KAMA 'closeTradeById()' ilishindwa (matokeo
  // yalikuwa yakipuuzwa - 'Future<void>' ya zamani). Hii ilimaanisha
  // kama Deriv ingekataa ombi la kuuza, TUNGEPOTEZA UFUATILIAJI wa
  // position ambayo BADO IKO WAZI kwenye Deriv - hatari kubwa. Sasa
  // tunathibitisha MAFANIKIO KWANZA - trade.closed inabaki 'false'
  // (na TradeRegistry haiondolewi) endapo kufunga kunashindwa, ili
  // 'tick' inayofuata ijaribu tena kiotomatiki.
  bool closed = false;

  try {
    closed = await DerivService.instance.closeTradeById(trade.contractId);
  } catch (e) {
    _trace("CLOSE ERROR", e);
  }

  if (!closed) {
    _trace(
      "CLOSE FAILED (itajaribiwa tena)",
      "${trade.contractId} - Deriv ilikataa/ilishindwa kufunga - "
      "'tick' inayofuata itajaribu tena kiotomatiki. Position BADO "
      "IKO WAZI kwenye Deriv.",
    );
    return;
  }

  trade.closed = true;

  TradeRegistry.instance.remove(trade.contractId);

  CURRENT_BALANCE = await _getBalance();

  _checkEquityProtection();
  _checkDailyLimits();

  _trace("TRADE CLOSED", {
    "contract": trade.contractId,
    "reason": reason,
    "balance": CURRENT_BALANCE,
  });
}

/// ================= SYMBOL NORMALIZER =================
// FIX: rahisishwa - inarudisha UPPERCASE TU (uwiano kamili na jinsi
// MarketAnalysisService/signals_server.dart zinavyoshughulikia majina
// ya alama kila mahali pengine kwenye mfumo huu). Kabla ya
// kutumika kwa Deriv HALISI, deriv.resolveOriginalCasing() INALAZIMIKA
// kuitwa kwanza (angalia _handleSignal()).
String _normalizeSymbol(String s) => s.toUpperCase().trim();

/// ================= STAKE (IMEANDIKWA UPYA - risk-based ya kweli) ====
// 🚨 FIX (bug hatari sana - "position sizing" ilikuwa haifanyi kazi
// kabisa): _calculateStake() ya awali ilitumia 'confidence' MOJA KWA
// MOJA kwenye masharti kama "if (confidence > 0.88)" - lakini
// 'confidence' halisi kutoka server 1 ni mizani 0-100 (mf. 70.0), hivyo
// MASHARTI HAYO YALIKUWA TRUE KILA WAKATI (70.0 > 0.88 daima) - kila
// trade ilikuwa ikipata 'base * 1.5' (kiwango cha JUU ZAIDI) bila
// kujali confidence halisi. Zaidi ya hilo, haikutumia 'stopDistance'
// KABISA - stake ilikuwa KIASI CHA FEDHA TU kilichowekwa (si sizing ya
// hatari ya kweli inayozingatia umbali wa SL).
//
// SASA: stake inahesabiwa kutoka riskAmount (asilimia ya balance,
// inayotegemea confidence) ikigawanywa na (multiplier * asilimia ya
// umbali wa SL) - MANTIKI ILE ILE HALISI tuliyoitumia kwenye backtest
// engine (market_analysis_service.dart runBacktest()), ikiwa na kikomo
// cha usalama dhidi ya "explosion" (stopDistance ndogo mno).

// =====================================================================
// ONGEZO JIPYA (kwa ombi la mtumiaji - usanifu safi zaidi): UAMUZI
// WA STAKE/MUDA MPYA baada ya hitilafu ya Deriv sasa unafanyika HAPA
// TU (trades.dart) - SI deriv_service.dart. deriv_service.dart
// inarudisha TU taarifa kamili za hitilafu (PlaceTradeResult), na
// SISI (hapa) tunaamua jinsi ya kujaribu tena, tukiheshimu
// MAX_STAKE_PERCENT_OF_BALANCE na MIN_STAKE muda wote.
// =====================================================================

class _TradeAttemptResult {
  final String? contractId;
  final PlaceTradeError? error;
  final double finalStake;

  _TradeAttemptResult({
    this.contractId,
    this.error,
    required this.finalStake,
  });

  bool get success => contractId != null;
}

// Kiwango cha chini kabisa cha stake tunachokubali kujaribu.
const double MIN_STAKE = 1.0;

Future<_TradeAttemptResult> _placeTradeWithRetries({
  required String derivSymbol,
  required String symbol,
  required bool isBuy,
  required double initialStake,
  required double balance,
}) async {
  final deriv = DerivService.instance;

  // 🔍 ONGEZO JIPYA (diagnostic - kwa ombi la mtumiaji): kabla ya
  // kujaribu trade, tunachunguza 'contracts_for' kuona muda HALISI
  // unaokubalika kwa Vanilla Options kwa alama hii - hii itatuonyesha
  // muundo halisi wa Deriv (fields za duration) ili tuweze kuacha
  // "kukisia" (24h, dakika 5) na kutumia thamani SAHIHI moja kwa
  // moja siku zijazo.
  await deriv.getContractDurationLimits(
    derivSymbol,
    isBuy ? "VANILLALONGCALL" : "VANILLALONGPUT",
  );

  double currentStake = initialStake;
  int durationValue = 24;
  String durationUnit = "h";

  // Kikomo cha juu cha majaribio - epuka mzunguko usio na mwisho
  // endapo hitilafu zisizotarajiwa zikiendelea kujitokeza.
  const maxAttempts = 3;

  PlaceTradeError? lastError;

  for (int attempt = 1; attempt <= maxAttempts; attempt++) {
    _trace("PLACE TRADE ATTEMPT $attempt/$maxAttempts", {
      "symbol": symbol,
      "stake": currentStake,
      "duration": "$durationValue$durationUnit",
    });

    final result = await deriv.placeTrade(
      derivSymbol,
      isBuy,
      stake: currentStake,
      durationValue: durationValue,
      durationUnit: durationUnit,
    );

    if (result.success) {
      return _TradeAttemptResult(
        contractId: result.contractId,
        finalStake: currentStake,
      );
    }

    lastError = result.error;

    _trace("PLACE TRADE ATTEMPT $attempt FAILED", "$lastError");

    if (attempt == maxAttempts) break;

    // ================= AINA 1: MUDA HAUKUBALIKI =================
    if (lastError?.code == "TradingDurationNotAllowed") {
      _trace(
        "RETRY DECISION",
        "Muda ($durationValue$durationUnit) haukubaliki - kujaribu "
        "tena na dakika 5.",
      );
      durationValue = 5;
      durationUnit = "m";
      continue;
    }

    // ================= AINA 2: KIKOMO CHA MALIPO (PAYOUT) =================
    // FIX (uthibitisho wa moja kwa moja kutoka Deriv - RAW response
    // halisi): "Minimum stake of 0.50 and maximum payout of 100.00.
    // Current payout is 1681.37." - 'codeArgs' ina [minStake,
    // maxPayout, currentPayout].
    if (lastError?.code == "ContractBuyValidationError" ||
        lastError?.subcode == "PayoutLimits") {
      final codeArgs = lastError?.codeArgs;

      if (codeArgs is List && codeArgs.length >= 3) {
        final maxPayout = double.tryParse(codeArgs[1].toString());
        final currentPayout = double.tryParse(codeArgs[2].toString());

        if (maxPayout != null && currentPayout != null && currentPayout > 0) {
          // Uwiano wa 90% ya kikomo - nafasi ndogo ya usalama.
          final scaleFactor = (maxPayout / currentPayout) * 0.9;
          var newStake = double.parse(
            (currentStake * scaleFactor).toStringAsFixed(2),
          );

          // FIX: HESHIMU MAX_STAKE_PERCENT_OF_BALANCE na MIN_STAKE
          // HATA baada ya kupunguzwa kwa sababu ya kikomo cha
          // malipo - hii ndiyo hasa sababu ya kuhamisha uamuzi huu
          // HAPA (trades.dart), si deriv_service.dart (ambayo
          // haikuwa ikijua kuhusu vikomo hivi vya hatari kabisa).
          final maxAllowedStake =
              balance * (MAX_STAKE_PERCENT_OF_BALANCE / 100);

          if (newStake > maxAllowedStake) newStake = maxAllowedStake;

          if (newStake < MIN_STAKE) {
            _trace(
              "RETRY DECISION",
              "Stake mpya (\$${newStake.toStringAsFixed(2)}) iko chini "
              "ya MIN_STAKE (\$$MIN_STAKE) - haiwezekani kuendelea.",
            );
            break;
          }

          _trace(
            "RETRY DECISION",
            "Kikomo cha malipo kimezidiwa - stake "
            "\$${currentStake.toStringAsFixed(2)} -> "
            "\$${newStake.toStringAsFixed(2)}.",
          );

          currentStake = newStake;
          continue;
        }
      }

      _trace(
        "RETRY DECISION",
        "Kikomo cha malipo - haikuweza kuhesabu stake mpya kutoka "
        "codeArgs: $codeArgs. Kukata tamaa.",
      );
      break;
    }

    // Aina nyingine ya hitilafu isiyotambulika - hakuna fallback ya
    // kiotomatiki, kata tamaa.
    _trace(
      "RETRY DECISION",
      "Hitilafu isiyotambulika (code=${lastError?.code}) - hakuna "
      "fallback ya kiotomatiki. Kukata tamaa.",
    );
    break;
  }

  return _TradeAttemptResult(error: lastError, finalStake: currentStake);
}


double _riskPercentFor(double confidence) {
  // 'confidence' ni mizani 0-100 (kutoka
  // market_analysis_service.dart._calculateConfidence()).
  if (confidence >= 88) return 1.5;
  if (confidence >= 80) return 1.2;
  if (confidence >= 75) return 1.0;
  return 0.5; // bado imepita MIN_CONFIDENCE, lakini ni dhaifu zaidi
}

double _calculateStake({
  required double confidence,
  required double balance,
  required double entry,
  required double stopLoss,
  required int multiplier,
}) {
  final riskPercent = _riskPercentFor(confidence);
  final riskAmount = balance * (riskPercent / 100);

  final stopDistance = (entry - stopLoss).abs();

  if (entry <= 0 || stopDistance <= 0) {
    // Salama: stake ndogo ya default badala ya kugawa kwa sifuri -
    // bado inaheshimu MIN_STAKE.
    return MIN_STAKE;
  }

  final slPercent = stopDistance / entry;

  final rawStake = riskAmount / (multiplier * slPercent);

  // Kikomo cha usalama - ulinzi dhidi ya "position sizing explosion"
  // (bug ile ile tuliyoipata kwenye backtest - stopDistance ndogo mno
  // ikilinganishwa na bei ikitoa namba isiyo ya busara).
  final maxStake = balance * (MAX_STAKE_PERCENT_OF_BALANCE / 100);

  final bounded = rawStake > maxStake ? maxStake : rawStake;

  // ⚠️ KUMBUKA MUHIMU: kulazimisha MIN_STAKE ($1) kunaweza wakati
  // mwingine kumaanisha hatari HALISI (dollar) inayochukuliwa ni
  // KUBWA ZAIDI ya asilimia iliyokusudiwa (mf. kwenye balance ndogo
  // sana kama $20, $1 ni 5% - zaidi ya risk% ya kawaida ya 0.5-1.5%).
  // Hii ni MADHARA YASIYOEPUKIKA ya kuwa na balance ndogo pamoja na
  // kiwango cha chini cha Deriv - si bug, ni ukweli wa kihesabu.
  // Ukiona hili likikusumbua, suluhisho pekee halisi ni balance kubwa
  // zaidi ya akaunti.
  final finalValue = bounded < MIN_STAKE ? MIN_STAKE : bounded;

  // FIX (uwiano na deriv_service.dart - Deriv inakataa stake yenye
  // desimali zaidi ya 2): rounding hapa pia inahakikisha thamani
  // zinazoripotiwa (ActiveTrade, _trace(), n.k.) ni safi/sahihi
  // tangu mwanzo, hata kabla ya kufika deriv_service.dart.
  return double.parse(finalValue.toStringAsFixed(2));
}