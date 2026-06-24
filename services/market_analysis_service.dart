import 'dart:async';
import 'dart:math';

import '../models/market_analysis_result.dart';
import '../models/candle.dart';
import '../models/risk_model.dart';
import 'deriv_service.dart';

enum MarketBias { buy, sell, none }

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

  final Duration cooldown = const Duration(seconds: 8);

  bool debugMode = true;

  void _log(String msg) {
    if (debugMode) print("[TOPDOWN] $msg");
  }

  // ================= START =================
  Future<void> startPairs(List<String> pairs) async {
    final deriv = DerivService.instance;

    await deriv.connect();

    _log("🚀 TOP-DOWN ENGINE STARTED");

    for (final p in pairs) {
      await deriv.subscribe(p);
    }

    deriv.stream.listen((event) {
      final type = event["msg_type"];
      final echo = event["echo_req"] ?? {};
      final symbol = echo["ticks_history"];

      if (type == "candles" && symbol != null) {
        _run(symbol);
      }
    });
  }

  // ================= RUN =================
  Future<void> _run(String pair) async {
    final now = DateTime.now();

    if (_isRunning[pair] == true) return;

    if (_lastRun[pair] != null &&
        now.difference(_lastRun[pair]!).inMilliseconds < 2500) {
      return;
    }

    _isRunning[pair] = true;
    _lastRun[pair] = now;

    try {
      final deriv = DerivService.instance;

      final w1 = deriv.getCandles(pair, TF.w1);
      final d1 = deriv.getCandles(pair, TF.d1);
      final h4 = deriv.getCandles(pair, TF.h4);
      final h1 = deriv.getCandles(pair, TF.h1);

      if (h1.length < 120) {
        _isRunning[pair] = false;
        return;
      }

      final result = _analyze(pair, w1, d1, h4, h1);

      _latest[pair] = result;
      _controller.add(result);

      _log("📊 $pair → BUY:${result.canBuy} SELL:${result.canSell}");
    } catch (e) {
      _log("❌ ERROR $pair → $e");
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
    if (h1.length < 10) return _empty(pair);

    final w1Bias = _bias(w1);
    final d1Bias = _bias(d1);
    final structureAligned =
        w1Bias == d1Bias && w1Bias != MarketBias.none;

    final sweepLow = _sweepLow(h4);
    final sweepHigh = _sweepHigh(h4);

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

    if (w1Bias == MarketBias.buy) buy += 30;
    if (w1Bias == MarketBias.sell) sell += 30;

    if (structureAligned && w1Bias == MarketBias.buy) buy += 25;
    if (structureAligned && w1Bias == MarketBias.sell) sell += 25;

    if (sweepLow) buy += 25;
    if (sweepHigh) sell += 25;

    if (engulfBull) buy += 20;
    if (engulfBear) sell += 20;

    final total = buy + sell;
    final confidence = total == 0 ? 0 : (max(buy, sell) / total) * 100;
    final dominance = (buy - sell).abs();

    final strong = confidence >= 65;
    final clear = dominance >= 20;

    bool isBuy = strong && clear && buy > sell;
    bool isSell = strong && clear && sell > buy;

    final lastSignal = _lastSignal[pair];
    final canSend = lastSignal == null ||
        DateTime.now().difference(lastSignal) > cooldown;

    isBuy = isBuy && canSend;
    isSell = isSell && canSend;

    if (isBuy || isSell) {
      _lastSignal[pair] = DateTime.now();
    }

    return MarketAnalysisResult(
      symbol: pair,

      candles: h1,
      candlesH1: h1,
      candlesM15: h4,
      candlesM30: d1,
      candlesM5: const [],

      canBuy: isBuy,
      canSell: isSell,

      structureValid: structureAligned,
      emaValid: true,
      rsiValid: true,
      confirmationValid: isBuy || isSell,
      filtersValid: confidence >= 65,

      ema50: const [],
      ema200: const [],

      indicators: {
        "w1Bias": w1Bias.toString(),
        "confidence": confidence,
        "dominance": dominance,
        "buyScore": buy,
        "sellScore": sell,
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

  // ================= EMPTY =================
  MarketAnalysisResult _empty(String pair) {
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
      reasonsFailed: const ["no data"],

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

  // ================= HELPERS =================
  MarketBias _bias(List<Candle> c) {
    if (c.length < 10) return MarketBias.none;

    final first = c.first.close;
    final last = c.last.close;

    if (last > first) return MarketBias.buy;
    if (last < first) return MarketBias.sell;
    return MarketBias.none;
  }

  bool _sweepLow(List<Candle> c) =>
      c.length > 2 && c.last.low < c[c.length - 2].low;

  bool _sweepHigh(List<Candle> c) =>
      c.length > 2 && c.last.high > c[c.length - 2].high;

  double _atr(List<Candle> c) {
    if (c.length < 2) return 0;

    int len = min(14, c.length - 1);
    double sum = 0;

    for (int i = c.length - len; i < c.length; i++) {
      sum += (c[i].high - c[i].low);
    }

    return sum / len;
  }

  // ================= FIX REQUIRED BY YOUR ERRORS =================
  List<String> get latestKeys => _latest.keys.toList();

  MarketAnalysisResult? latestFor(String pair) => _latest[pair];
}