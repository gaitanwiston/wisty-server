import 'dart:async';
import 'dart:math';

import '../models/market_analysis_result.dart';
import '../models/candle.dart';
import '../models/risk_model.dart';
import 'deriv_service.dart';

// ================= ENUMS =================
enum MarketBias { buy, sell, none }
enum MarketSession { asia, london, newYork, sydney, unknown }

enum TimeFrame { m1, h1, h4, d1, w1 }

// ================= STRUCTURES =================
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

// ================= ENGINE =================
class MarketAnalysisService {
  MarketAnalysisService._internal();
  static final instance = MarketAnalysisService._internal();

  final StreamController<MarketAnalysisResult> _controller =
      StreamController.broadcast();

  Stream<MarketAnalysisResult> get analysisStream => _controller.stream;

  final Map<String, int> _lastSize = {};
  final Map<String, MarketAnalysisResult> _latest = {};
  final Map<String, DateTime> _lastUpdate = {};
  final Map<String, DateTime> _lastSignalTime = {};

  Timer? _globalAnalysisTimer;
  final Duration signalCooldown = const Duration(seconds: 30);

  bool debugMode = true;

  // ================= NORMALIZER (ULTRA FIXED) =================
  String _norm(String s) {
    return s
        .toUpperCase()
        .replaceAll("FRX", "")
        .replaceAll("OTC", "")
        .replaceAll("R_", "")
        .replaceAll("_", "")
        .replaceAll("-", "")
        .trim();
  }

  void _log(String msg) {
    if (debugMode) {
      print("[PROMAX ULTRA NEXT] $msg");
    }
  }

  // ================= START =================
Future<void> startPairs(List<String> pairs) async {
  final deriv = DerivService.instance;

  await deriv.connect();

  for (final p in pairs) {
    final key = _norm(p);

    deriv.subscribe(p);

    _lastSize[key] = 0;

    _log("SUBSCRIBED PAIR → $key");
  }

  Timer.periodic(const Duration(seconds: 5), (_) async {
    for (final p in pairs) {
      try {
        final key = _norm(p);

        _log("CHECKING PAIR → $key");

        final h1 = await deriv.getCandles(p, TF.h1);

        _log("CANDLES RECEIVED → $key : ${h1.length}");

        if (h1.length < 120) {
          _log("SKIP $key → insufficient candles");
          continue;
        }

        _log("RUNNING ANALYSIS → $key");

        final h4 = await deriv.getCandles(p, TF.h4);
        final d1 = await deriv.getCandles(p, TF.d1);
        final w1 = await deriv.getCandles(p, TF.w1);

        final result = _analyze(
          key,
          w1,
          d1,
          h4,
          h1,
        );

        _latest[key] = result;
        _lastUpdate[key] = DateTime.now();

        _log("CACHE SAVED → $key");
        _log("CACHE KEYS → ${_latest.keys.toList()}");
      } catch (e, s) {
        _log("ERROR $p");
        _log("$e");
        _log("$s");
      }
    }
  });
}

  // ================= ANALYSIS =================
  MarketAnalysisResult _analyze(
    String pair,
    List<Candle> w1,
    List<Candle> d1,
    List<Candle> h4,
    List<Candle> h1,
  ) {
    final key = _norm(pair);

    if (h1.length < 3) return _emptyResult(key);

    final w1Bias = _bias(w1);
    final d1Bias = _bias(d1);
    final trendAligned = (w1Bias == d1Bias) && w1Bias != MarketBias.none;

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

    if (engulfBull) buy += 40;
    if (engulfBear) sell += 40;

    final confidence = max(buy, sell);

    bool isBuy = buy > sell && confidence >= 60;
    bool isSell = sell > buy && confidence >= 60;

    final lastSignal = _lastSignalTime[key];
    final canSend = lastSignal == null ||
        DateTime.now().difference(lastSignal) > signalCooldown;

    isBuy = isBuy && canSend;
    isSell = isSell && canSend;

    if (isBuy || isSell) {
      _lastSignalTime[key] = DateTime.now();
    }

    _log("ANALYSIS $key → BUY:$buy SELL:$sell CONF:$confidence");
_log("CACHE KEYS: ${_latest.keys.toList()}");
    return MarketAnalysisResult(
      symbol: key,
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
      filtersValid: confidence > 60,
      ema50: const [],
      ema200: const [],
      indicators: {
        "buy": buy,
        "sell": sell,
        "confidence": confidence,
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
        direction: isBuy ? "BUY" : isSell ? "SELL" : "NONE",
      ),
    );
  }

  // ================= GUARANTEED EMPTY =================
  MarketAnalysisResult _emptyResult(String key) {
    return MarketAnalysisResult(
      symbol: key,
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
      reasonsFailed: const ["init"],
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
    int up = 0, down = 0;
    for (int i = 1; i < c.length; i++) {
      if (c[i].close > c[i - 1].close) up++;
      if (c[i].close < c[i - 1].close) down++;
    }

    if (up > down + 8) return MarketBias.buy;
    if (down > up + 8) return MarketBias.sell;
    return MarketBias.none;
  }

  double _atr(List<Candle> c) {
    int len = min(14, c.length - 1);
    double sum = 0;

    for (int i = c.length - len; i < c.length; i++) {
      sum += (c[i].high - c[i].low);
    }

    return len == 0 ? 0 : sum / len;
  }

  MarketAnalysisResult? latestFor(String pair) {
    final key = _norm(pair);

    _log("LOOKUP → $key EXISTS:${_latest.containsKey(key)}");

    return _latest[key];
  }
}