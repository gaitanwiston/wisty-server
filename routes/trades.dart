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

    // 🚨 FIX (usalama mkubwa sana): sasa tunapitisha entry/SL/TP kwa
    // placeTrade() ili DERIV YENYEWE itekeleze 'limit_order' (SL/TP
    // halisi upande wa broker). Awali haya HAYAKUWA yakipitishwa
    // KABISA - trade zilikuwa zikifunguliwa BILA ULINZI WOWOTE wa
    // SL/TP upande wa Deriv, zikitegemea TU ufuatiliaji wa bei wa
    // ndani ya server hii (_subscribeToTrade chini) - hatari kubwa
    // endapo server hii ingeanguka/kukatika wakati position ikiwa
    // wazi (position ingebaki bila ulinzi WOWOTE).
    final contractId = await deriv.placeTrade(
      derivSymbol,
      isBuy,
      stake: stake,
      entryPrice: entry,
      stopLossPrice: sl,
      takeProfitPrice: tp,
      multiplier: DEFAULT_MULTIPLIER,
    );

    if (contractId == null) {
      _trace("ERROR", "TRADE FAILED");
      return Response.json(body: {"error": "TRADE_FAILED"});
    }

    _trace("SUCCESS", contractId);

    final trade = ActiveTrade(
      contractId: contractId,
      pair: symbol,
      buy: isBuy,
      entry: entry,
      sl: sl,
      tp: tp,
    );

    TradeRegistry.instance.register(trade);
    _subscribeToTrade(trade);

    return Response.json(body: {
      "status": "EXECUTED",
      "contractId": contractId,
      "symbol": symbol,
      "stake": stake,
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
// KUMBUKA: hii inabaki kama ULINZI WA ZIADA (defense-in-depth) - hata
// baada ya Deriv kuwa na 'limit_order' halisi (SL/TP upande wa broker),
// ufuatiliaji huu wa ndani unatoa safu ya pili + unashughulikia
// "breakeven" (kuhamisha SL hadi entry baada ya faida ya 1R).
//
// ⚠️ KIKOMO KILICHOBAKI: 'trade.sl = trade.entry' (breakeven) hapa
// inabadilisha TU thamani ya NDANI (kwa ufuatiliaji wa server hii) -
// HAIBADILISHI 'limit_order.stop_loss' halisi iliyowekwa Deriv wakati
// wa kufungua trade (Deriv haijui kuhusu "breakeven" hii). Kubadilisha
// SL halisi ya Deriv kunahitaji ombi jipya la 'contract_update' -
// haijatengenezwa humu bado. Kwa sasa, breakeven ni ulinzi wa ZIADA wa
// ndani TU, si uingizwaji wa SL ya Deriv - niambie ukihitaji
// 'contract_update' iongezwe.
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
      trade.sl = trade.entry;
      trade.breakeven = true;
      _trace("BREAKEVEN (ndani TU)", trade.contractId);
    }

    final tpHit = trade.buy ? price >= trade.tp : price <= trade.tp;
    final slHit = trade.buy ? price <= trade.sl : price >= trade.sl;

    if (tpHit || slHit) {
      await _closeTrade(trade, reason: tpHit ? "TP" : "SL");
    }
  });

  TradeRegistry.instance.subscriptions[trade.contractId] = sub;
}

/// ================= CLOSE =================
Future<void> _closeTrade(ActiveTrade trade, {required String reason}) async {
  if (trade.closed) return;

  trade.closed = true;

  try {
    await DerivService.instance.closeTradeById(trade.contractId);
  } catch (e) {
    _trace("CLOSE ERROR", e);
  }

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
    // Salama: stake ndogo ya default badala ya kugawa kwa sifuri.
    return balance * 0.005;
  }

  final slPercent = stopDistance / entry;

  final rawStake = riskAmount / (multiplier * slPercent);

  // Kikomo cha usalama - ulinzi dhidi ya "position sizing explosion"
  // (bug ile ile tuliyoipata kwenye backtest - stopDistance ndogo mno
  // ikilinganishwa na bei ikitoa namba isiyo ya busara).
  final maxStake = balance * (MAX_STAKE_PERCENT_OF_BALANCE / 100);

  return rawStake > maxStake ? maxStake : rawStake;
}