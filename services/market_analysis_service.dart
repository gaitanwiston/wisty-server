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
  List<String> get latestKeys => _latest.keys.toList();

  final Set<String> _queue = {};
  final Map<String, DateTime> _lastRun = {};
  final Map<String, DateTime> _lastEvent = {};

  final Duration cooldown = const Duration(seconds: 3);
  bool debugMode = true;

  void _log(String msg) {
    if (debugMode) print("[SERVER2-ENGINE] $msg");
  }

  // 🔥 FIX 1: Proper normalization (FRXUSDCAD issue fix)
  String _normalize(String s) {
    return s
        .toUpperCase()
        .replaceAll("FRX", "")
        .replaceAll("_", "")
        .trim();
  }

  // ================= START =================
  Future<void> startPairs(List<String> pairs) async {
    final deriv = DerivService.instance;

    await deriv.connect();
    _log("🚀 ENGINE STARTED");

    for (final p in pairs) {
      final symbol = _normalize(p);
      await deriv.subscribe(symbol);
    }

    deriv.stream.listen((event) {
      final type = event["msg_type"];
      final echo = event["echo_req"] ?? {};
      final raw = echo["ticks_history"];

      if (raw == null) return;

      final symbol = _normalize(raw);
      final now = DateTime.now();

      if (_lastEvent[symbol] != null &&
          now.difference(_lastEvent[symbol]!).inMilliseconds < 1200) {
        return;
      }

      _lastEvent[symbol] = now;

      if (type == "candles" ||
          type == "candles_update" ||
          type == "ohlc") {
        _queue.add(symbol);
      }
    });

    Timer.periodic(const Duration(milliseconds: 800), (_) {
      _processQueue();
    });
  }

  // ================= QUEUE =================
  Future<void> _processQueue() async {
    if (_queue.isEmpty) return;

    final symbol = _queue.first;
    _queue.remove(symbol);

    await _run(symbol);
  }

  // ================= RUN =================
  Future<void> _run(String pair) async {
    final now = DateTime.now();

    if (_lastRun[pair] != null &&
        now.difference(_lastRun[pair]!).inMilliseconds < 2500) {
      return;
    }

    _lastRun[pair] = now;

    try {
      final deriv = DerivService.instance;

      final h1 = deriv.getCandles(pair, TF.h1);
      final h4 = deriv.getCandles(pair, TF.h4);
      final d1 = deriv.getCandles(pair, TF.d1);
      final w1 = deriv.getCandles(pair, TF.w1);

      if (h1.length < 120) {
        _log("⚠️ SKIP $pair → insufficient data (${h1.length})");
        return;
      }

      final result = _analyze(pair, w1, d1, h4, h1);

      _latest[pair] = result;
      _controller.add(result);

      _log("✅ UPDATED $pair | BUY:${result.canBuy} SELL:${result.canSell}");
    } catch (e) {
      _log("❌ ERROR $pair → $e");
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
    final w1Bias = _bias(w1);
    final d1Bias = _bias(d1);

    final trendAligned =
        (w1Bias == d1Bias) && w1Bias != MarketBias.none;

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

    if (h1Buy) buy += 20;
    if (h1Sell) sell += 20;

    if (engulfBull) buy += 20;
    if (engulfBear) sell += 20;

    final total = buy + sell;
    final confidence =
        total == 0 ? 0 : (max(buy, sell) / total) * 100;

    final strong = confidence >= 60;

    final isBuy = strong && buy > sell;
    final isSell = strong && sell > buy;

    final atr = _atr(h1);

    // 🔥 FIX 2: Prevent zero price crash
    final entry = h1.last.close;
    if (entry <= 0 || atr <= 0) {
      return MarketAnalysisResult(
        symbol: pair,
        candles: h1,
        candlesH1: h1,
        candlesM15: h4,
        candlesM30: d1,
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
        indicators: {
          "error": "INVALID_PRICE_DATA"
        },
        entryCandles: const [],
        structurePoints: const [],
        conditionsMet: const [],
        reasonsFailed: const ["Invalid entry or ATR = 0"],
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
      filtersValid: confidence >= 60,

      ema50: const [],
      ema200: const [],

      indicators: {
        "buy": buy,
        "sell": sell,
        "confidence": confidence,
        "trendAligned": trendAligned,
      },

      entryCandles: const [],
      structurePoints: const [],
      conditionsMet: const [],
      reasonsFailed: const [],

      stopLoss: isBuy ? entry - atr : entry + atr,
      takeProfit: isBuy ? entry + atr * 3 : entry - atr * 3,

      structureBuy: isBuy,
      structureSell: isSell,
      biasIsBuy: isBuy,

      isValidTrade: isBuy || isSell,

      risk: RiskModel(
        entry: entry,
        stopLoss: isBuy ? entry - atr : entry + atr,
        takeProfit: isBuy ? entry + atr * 3 : entry - atr * 3,
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

  double _atr(List<Candle> c) {
    if (c.length < 2) return 0;

    int len = min(14, c.length - 1);
    double sum = 0;

    for (int i = c.length - len; i < c.length; i++) {
      sum += (c[i].high - c[i].low);
    }

    return sum / len;
  }

  MarketAnalysisResult? latestFor(String pair) => _latest[pair];
}