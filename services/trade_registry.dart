import 'dart:async';

// =====================================================================
// services/trade_registry.dart
// =====================================================================
//
// SABABU YA KUUNDWA: 'route/trades.dart' ilikuwa ikihifadhi trades
// zilizo wazi kwenye variable ya 'private' (_activeTrades) - kwa
// kanuni za Dart, majina yenye '_' mbele ni ya FAILI HILO HILO TU,
// HAYAWEZI kufikiwa kutoka faili nyingine HATA kwa 'import'. Hii
// ilimaanisha 'candles.dart' (au route yoyote nyingine) haikuwa na
// njia YOYOTE ya kujua "je alama hii ina trade wazi, na SL/TP yake
// HALISI (kama ilivyowekwa Deriv wakati trade ilipofunguliwa) ni ipi".
//
// Sasa 'TradeRegistry' ni hifadhi MOJA ya KUDUMU (singleton),
// inayoweza kufikiwa na route ZOTE - 'trades.dart' inaandika (wakati
// trade inafunguliwa/kufungwa), 'candles.dart' (au route nyingine
// yoyote) inasoma TU.
//
// ONGEZO JIPYA: 'stake'/'multiplier' - zinahitajika kuhesabu KIASI CHA
// FEDHA sahihi wakati wa kubadilisha SL/TP HALISI za Deriv baadaye
// (kupitia 'contract_update' - angalia deriv_service.dart.
// updateContractSLTP()) - bila kujua stake/multiplier ya AWALI,
// haiwezekani kubadilisha bei mpya ya TP kuwa kiasi sahihi cha fedha
// kinachohitajika na Deriv.

class ActiveTrade {
  final String contractId;
  final String pair; // UPPERCASE - sawa na jinsi MarketAnalysisService inavyotumia majina
  final bool buy;
  final double entry;
  double sl;
  double tp;
  double current;

  // ONGEZO JIPYA: zinahitajika kwa 'updateContractSLTP()' (kuhesabu
  // kiasi cha fedha sahihi cha TP mpya).
  final double stake;
  final int multiplier;

  bool breakeven = false;
  bool closed = false;

  final DateTime openedAt;

  // ONGEZO JIPYA: muda wa mwisho tulipoangalia kama TP inafaa
  // kupanuliwa (throttle - usiangalie kila 'tick', angalia kila muda
  // fulani TU - angalia _subscribeToTrade() kwenye trades.dart).
  DateTime? lastTpCheck;

  ActiveTrade({
    required this.contractId,
    required this.pair,
    required this.buy,
    required this.entry,
    required this.sl,
    required this.tp,
    this.stake = 0,
    this.multiplier = 100,
    this.current = 0,
    DateTime? openedAt,
  }) : openedAt = openedAt ?? DateTime.now().toUtc();
}

class TradeRegistry {
  TradeRegistry._internal();
  static final TradeRegistry instance = TradeRegistry._internal();

  final Map<String, ActiveTrade> trades = {};
  final Map<String, StreamSubscription> subscriptions = {};

  void register(ActiveTrade trade) {
    trades[trade.contractId] = trade;
  }

  void remove(String contractId) {
    subscriptions[contractId]?.cancel();
    subscriptions.remove(contractId);
    trades.remove(contractId);
  }

  /// Inarudisha trade iliyo WAZI (haijafungwa) kwa alama fulani (jina
  /// lolote - inasawazishwa UPPERCASE ndani), au null kama hakuna.
  ActiveTrade? activeTradeFor(String pair) {
    final upper = pair.trim().toUpperCase();

    for (final t in trades.values) {
      if (!t.closed && t.pair == upper) return t;
    }

    return null;
  }

  bool hasOpenTrade(String pair) => activeTradeFor(pair) != null;

  int get count => trades.values.where((t) => !t.closed).length;
}