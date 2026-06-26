import 'dart:async';
import 'dart:math';

import '../models/market_analysis_result.dart';
import '../models/candle.dart';
import '../models/risk_model.dart';
import 'deriv_service.dart';

enum MarketBias { buy, sell, none }

class Structure {
  final bool bosUp;
  final bool bosDown;
  final bool chochUp;
  final bool chochDown;

  Structure({
    required this.bosUp,
    required this.bosDown,
    required this.chochUp,
    required this.chochDown,
  });
}

class Liquidity {
  final bool sweepHigh;
  final bool sweepLow;
  final int equalHighs;
  final int equalLows;

  Liquidity({
    required this.sweepHigh,
    required this.sweepLow,
    required this.equalHighs,
    required this.equalLows,
  });
}

class OrderBlock {
  final bool validBullish;
  final bool validBearish;
  final double strength;

  OrderBlock({
    required this.validBullish,
    required this.validBearish,
    required this.strength,
  });
}

class MarketAnalysisService {
  MarketAnalysisService._internal();
  static final instance = MarketAnalysisService._internal();

  final StreamController<MarketAnalysisResult> _controller =
      StreamController.broadcast();

  Stream<MarketAnalysisResult> get analysisStream => _controller.stream;

  final Map<String, MarketAnalysisResult> _latest = {};
  final Map<String, bool> _isRunning = {};
  final Map<String, DateTime> _lastRun = {};
  final Map<String, DateTime> _lastSignal = {};
  final Map<String, DateTime> _lastEvent = {};

  final Duration cooldown = const Duration(seconds: 8);

  List<String> get latestKeys => _latest.keys.toList();

  bool debugMode = true;

  void _log(String msg) {
    if (debugMode) print("[SERVER2-MIRROR] $msg");
  }

  String _normalize(String s) {
    return s.toUpperCase().trim().replaceAll("_", "");
  }

  // ================= START =================
  Future<void> startPairs(List<String> pairs) async {
    final deriv = DerivService.instance;

    await deriv.connect();

    _log("🚀 SERVER2 STARTED (MIRROR MODE)");

    for (final p in pairs) {
      await deriv.subscribe(p);
      _isRunning[p] = false;
    }

    deriv.stream.listen((event) {
      final type = event["msg_type"];
      final echo = event["echo_req"] ?? {};
      final symbol = echo["ticks_history"];

      if (symbol == null) return;

      final now = DateTime.now();
      final key = _normalize(symbol);

      // 🔥 GLOBAL EVENT THROTTLE (VERY IMPORTANT)
      if (_lastEvent[key] != null &&
          now.difference(_lastEvent[key]!).inMilliseconds < 1500) {
        return;
      }
      _lastEvent[key] = now;

      _log("📩 EVENT → $type | $key");

      if (type == "candles" ||
          type == "candles_update" ||
          type == "ohlc") {
        _run(key);
      }
    });
  }

  // ================= RUN =================
  Future<void> _run(String pair) async {
    final now = DateTime.now();

    if (_isRunning[pair] == true) return;

    if (_lastRun[pair] != null &&
        now.difference(_lastRun[pair]!).inMilliseconds < 3000) {
      return;
    }

    _isRunning[pair] = true;
    _lastRun[pair] = now;

    try {
      final deriv = DerivService.instance;

      _log("🔥 ANALYSIS → $pair");

      final h1 = deriv.getCandles(pair, TF.h1);
      final h4 = deriv.getCandles(pair, TF.h4);
      final d1 = deriv.getCandles(pair, TF.d1);
      final w1 = deriv.getCandles(pair, TF.w1);

      _log("📊 DATA SIZE H1:${h1.length} H4:${h4.length}");

      if (h1.length < 120) {
        _log("⚠️ SKIP $pair → insufficient data");
        _isRunning[pair] = false;
        return;
      }

      final result = _analyze(pair, w1, d1, h4, h1);

      _latest[pair] = result;
      _controller.add(result);

      _log("✅ CACHE UPDATED → $pair");
      _log("➡️ BUY:${result.canBuy} SELL:${result.canSell}");
    } catch (e, st) {
      _log("❌ ERROR $pair → $e");
      _log("$st");
    } finally {
      _isRunning[pair] = false;
    }
  }

  // ================= ANALYSIS =================
  MarketAnalysisResult _analyze(
    String pair,
    List<Candle> w1,
    List<Candle> d1,
    List<Candle> h4,
    List<Candle> h1,
  ) {
    _log("══════════════════════════════");
    _log("📊 ANALYSIS: $pair");
    _log("══════════════════════════════");

    final w1Bias = _bias(w1);
    final d1Bias = _bias(d1);

    final trendAligned =
        (w1Bias == d1Bias) && w1Bias != MarketBias.none;

    final liquidity = _liquidity(h4);
    final ob = _orderBlock(h4);

    final last5 = h1.sublist(max(0, h1.length - 5));

    int bull = 0, bear = 0;
    for (final c in last5) {
      if (c.close > c.open) bull++;
      if (c.close < c.open) bear++;
    }

    final h1Buy = bull >= 3;
    final h1Sell = bear >= 3;

    final last = h1.last;
    final prev = h1[h1.length - 2];

    final engulfBull =
        last.close > last.open &&
        prev.close < prev.open &&
        last.close > prev.open;

    final engulfBear =
        last.close < last.open &&
        prev.close > prev.open &&
        last.close < prev.open;

    double buy = 0;
    double sell = 0;

    if (trendAligned && w1Bias == MarketBias.buy) buy += 35;
    if (trendAligned && w1Bias == MarketBias.sell) sell += 35;

    if (liquidity.sweepLow) buy += 25;
    if (liquidity.sweepHigh) sell += 25;

    if (ob.validBullish) buy += 25;
    if (ob.validBearish) sell += 25;

    if (h1Buy) buy += 15;
    if (h1Sell) sell += 15;

    if (engulfBull) buy += 15;
    if (engulfBear) sell += 15;

    final total = buy + sell;
    final dominance = (buy - sell).abs();

    final confidence =
        total == 0 ? 0 : (max(buy, sell) / total) * 100;

    final strongTrend = confidence >= 65;
    final clearEdge = dominance >= 25;
    final structureOk = trendAligned;

    bool isBuy =
        strongTrend && clearEdge && structureOk && buy > sell;

    bool isSell =
        strongTrend && clearEdge && structureOk && sell > buy;

    _log("📊 BUY:$buy SELL:$sell CONF:$confidence");

    return MarketAnalysisResult(
      symbol: pair,
      candles: h1,
      candlesH1: h1,
      candlesM15: h4,
      candlesM30: d1,
      candlesM5: const [],

      canBuy: isBuy,
      canSell: isSell,

      structureValid: true,
      emaValid: true,
      rsiValid: true,
      confirmationValid: isBuy || isSell,
      filtersValid: confidence >= 65,

      ema50: const [],
      ema200: const [],

      indicators: {
        "buy": buy,
        "sell": sell,
        "confidence": confidence,
        "dominance": dominance,
        "trendAligned": trendAligned,
      },

      entryCandles: const [],
      structurePoints: const [],
      conditionsMet: const [],
      reasonsFailed: const [],

      stopLoss: _atr(h1),
      takeProfit: _atr(h1) * 3,

      structureBuy: isBuy,
      structureSell: isSell,
      biasIsBuy: isBuy,

      isValidTrade: isBuy || isSell,

      risk: RiskModel(
        entry: h1.last.close,
        stopLoss: isBuy
            ? h1.last.close - _atr(h1)
            : h1.last.close + _atr(h1),
        takeProfit: isBuy
            ? h1.last.close + _atr(h1) * 3
            : h1.last.close - _atr(h1) * 3,
        lotSize: 0.1,
        direction: isBuy
            ? "BUY"
            : isSell
                ? "SELL"
                : "NONE",
      ),
    );
  }

  // ================= HELPERS =================
  MarketBias _bias(List<Candle> c) {
    if (c.length < 10) return MarketBias.none;

    final first = c.first.close;
    final last = c.last.close;

    if (last > first) return MarketBias.buy;
    if (last < first) return MarketBias.sell;
    return MarketBias.none;
  }

  Liquidity _liquidity(List<Candle> c) {
    if (c.length < 2) {
      return Liquidity(
        sweepHigh: false,
        sweepLow: false,
        equalHighs: 0,
        equalLows: 0,
      );
    }

    return Liquidity(
      sweepHigh: c.last.high > c[c.length - 2].high,
      sweepLow: c.last.low < c[c.length - 2].low,
      equalHighs: 0,
      equalLows: 0,
    );
  }

  OrderBlock _orderBlock(List<Candle> c) {
    if (c.length < 3) {
      return OrderBlock(
        validBullish: false,
        validBearish: false,
        strength: 0,
      );
    }

    final last = c.last;
    final prev = c[c.length - 2];

    return OrderBlock(
      validBullish: last.close > last.open && last.close > prev.high,
      validBearish: last.close < last.open && last.close < prev.low,
      strength: 0.5,
    );
  }

  double _atr(List<Candle> c) {
    if (c.length < 2) return 0;

    int len = min(14, c.length - 1);
    double sum = 0;

    for (int i = c.length - len; i < c.length; i++) {
      sum += (c[i].high - c[i].low);
    }

    return sum / len;
  }

  MarketAnalysisResult _fallback(String pair) {
    return MarketAnalysisResult(
      symbol: pair,
      candles: const [],
      candlesH1: const [],
      candlesM15: const [],
      candlesM30: const [],
      candlesM5: const [],
      canBuy: false,
      canSell: false,
      structureValid: false,
      emaValid: false,
      rsiValid: false,
      confirmationValid: false,
      filtersValid: false,
      ema50: const [],
      ema200: const [],
      indicators: const {},
      entryCandles: const [],
      structurePoints: const [],
      conditionsMet: const [],
      reasonsFailed: const ["fallback"],
      stopLoss: 0,
      takeProfit: 0,
      structureBuy: false,
      structureSell: false,
      biasIsBuy: false,
      isValidTrade: false,
      risk: RiskModel(
        entry: 0,
        stopLoss: 0,
        takeProfit: 0,
        lotSize: 0,
        direction: "NONE",
      ),
    );
  }

  MarketAnalysisResult? latestFor(String pair) => _latest[pair];
}