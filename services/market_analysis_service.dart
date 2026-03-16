// ==========================================
// WISTY FX – SMART MARKET ANALYSIS v11.4 (Stable Server Build)
// Null-safe, ATR/SLTP, Multi-Timeframe, Production Ready
// ==========================================

import 'dart:async';
import 'dart:math';
import '../models/candle.dart';
import '../models/market_analysis_result.dart';

enum MarketBias { buy, sell, none }
enum EntryConfirmation { bullish, bearish, none }

class MarketAnalysisService {
  MarketAnalysisService._internal();
  static final MarketAnalysisService instance =
      MarketAnalysisService._internal();
  factory MarketAnalysisService() => instance;

  final _controller = StreamController<MarketAnalysisResult>.broadcast();
  Stream<MarketAnalysisResult> get analysisStream => _controller.stream;

  final Map<String, List<Candle>> _candlesM1 = {};
  final Map<String, List<Candle>> _candlesM5 = {};
  final Map<String, List<Candle>> _candlesM15 = {};
  final Map<String, List<Candle>> _candlesM30 = {};
  final Map<String, MarketAnalysisResult> _latest = {};

  int rsiPeriod = 14;
  int atrPeriod = 14;
  double defaultRR = 2.0;
  int minCandles = 100;
  int maxCandlesStored = 500;

  bool useATRforSLTP = true;

  int sessionStartHour = 8;
  int sessionEndHour = 22;
  Duration timezoneOffset = const Duration(hours: 3);

  static const bool isDebug = bool.fromEnvironment('dart.vm.product') == false;

  // =====================================================
  // TICK ENTRY
  // =====================================================

  void addTick(String pair, dynamic epochInput, double price) {
    try {
      final p = _normalize(pair);
      final epoch = _parseEpoch(epochInput);

      _candlesM1[p] =
          _addTickToCandles(_candlesM1[p] ?? [], price, epoch, timeframe: 1);

      _candlesM5[p] = _aggregate(_candlesM1[p]!, timeframeMinutes: 5);
      _candlesM15[p] = _aggregate(_candlesM1[p]!, timeframeMinutes: 15);
      _candlesM30[p] = _aggregate(_candlesM1[p]!, timeframeMinutes: 30);

      _pruneCandles(p, 1);
      _pruneCandles(p, 5);
      _pruneCandles(p, 15);
      _pruneCandles(p, 30);

      if ((_candlesM1[p]?.length ?? 0) >= minCandles) {
        final result = _analyze(
          p,
          m1: _candlesM1[p]!,
          m5: _candlesM5[p] ?? [],
          m15: _candlesM15[p] ?? [],
          m30: _candlesM30[p] ?? [],
        );

        _latest[p] = result;
        _controller.add(result);
      }
    } catch (e, st) {
      if (isDebug) {
        print("⚠ addTick error: $e\n$st");
      }
    }
  }

  // =====================================================
  // EXTERNAL ANALYSIS ENTRY
  // =====================================================

  Future<MarketAnalysisResult> analyzeMarket(
      String symbol, List<Candle> candles, int timeframeMinutes) async {
    final p = _normalize(symbol);
    final clean = _sanitize(candles);

    if (clean.length < minCandles) {
      return MarketAnalysisResult(
        symbol: p,
        candles: List.unmodifiable(clean),
        canBuy: false,
        canSell: false,
        reasonsFailed: ["Not enough candles"],
      );
    }

    switch (timeframeMinutes) {
      case 1:
        _candlesM1[p] = clean;
        break;
      case 5:
        _candlesM5[p] = clean;
        break;
      case 15:
        _candlesM15[p] = clean;
        break;
      case 30:
        _candlesM30[p] = clean;
        break;
    }

    final result = _analyze(
      p,
      m1: _candlesM1[p] ?? clean,
      m5: _candlesM5[p] ?? clean,
      m15: _candlesM15[p] ?? clean,
      m30: _candlesM30[p] ?? clean,
    );

    _latest[p] = result;
    _controller.add(result);

    return result;
  }

  MarketAnalysisResult? latestFor(String pair) => _latest[_normalize(pair)];

  // =====================================================
  // CORE ANALYSIS ENGINE
  // =====================================================

  MarketAnalysisResult _analyze(
    String pair, {
    required List<Candle> m1,
    required List<Candle> m5,
    required List<Candle> m15,
    required List<Candle> m30,
  }) {
    final reasonsOk = <String>[];
    final reasonsNo = <String>[];

    final bias = _detectStructure(m30);

    final structureBuy = bias == MarketBias.buy;
    final structureSell = bias == MarketBias.sell;

    if (bias == MarketBias.none) {
      reasonsNo.add("No clear structure");
    } else {
      reasonsOk.add("Structure ${bias.name}");
    }

    final ema50 = _calcEMA(m15, 50);
    final ema200 = _calcEMA(m15, 200);

    bool emaBuy = false;
    bool emaSell = false;

    if (ema50.isNotEmpty && ema200.isNotEmpty) {
      emaBuy = ema50.last > ema200.last && m1.last.close > ema50.last;
      emaSell = ema50.last < ema200.last && m1.last.close < ema50.last;
    }

    if (emaBuy || emaSell) {
      reasonsOk.add("EMA trend ok");
    } else {
      reasonsNo.add("EMA not aligned");
    }

    final rsi = _calcRSI(m15, rsiPeriod);

    final rsiBuy = rsi >= 52 && rsi <= 68;
    final rsiSell = rsi <= 48 && rsi >= 32;

    if (rsiBuy || rsiSell) {
      reasonsOk.add("RSI momentum ok");
    } else {
      reasonsNo.add("RSI not good ($rsi)");
    }

    final conf = _confirmation(m1, bias);

    final confBuy = conf == EntryConfirmation.bullish;
    final confSell = conf == EntryConfirmation.bearish;

    if (confBuy || confSell) {
      reasonsOk.add("Entry confirmed");
    } else {
      reasonsNo.add("No entry candle");
    }

    final entry = m1.isNotEmpty ? m1.last.close.toDouble() : 0.0;

    final sl = useATRforSLTP ? _atrSL(m1, bias) : _stopLoss(m1, bias);

    final tp = useATRforSLTP
        ? _atrTP(entry, sl, bias, defaultRR)
        : _takeProfit(entry, sl, bias, defaultRR);

    final sessionOk = _checkSession();
    final riskOk = _checkRR(entry, sl, tp);

    if (!sessionOk) reasonsNo.add("Bad session");
    if (!riskOk) reasonsNo.add("Bad RR");

    final canBuy =
        structureBuy && emaBuy && rsiBuy && confBuy && sessionOk && riskOk;

    final canSell =
        structureSell && emaSell && rsiSell && confSell && sessionOk && riskOk;

    return MarketAnalysisResult(
      symbol: pair,
      candles: List.unmodifiable(m1),
      candlesM5: List.unmodifiable(m5),
      candlesM15: List.unmodifiable(m15),
      candlesM30: List.unmodifiable(m30),
      structureValid: structureBuy || structureSell,
      emaValid: emaBuy || emaSell,
      rsiValid: rsiBuy || rsiSell,
      confirmationValid: confBuy || confSell,
      filtersValid: sessionOk && riskOk,
      canBuy: canBuy,
      canSell: canSell,
      structureBuy: structureBuy,
      structureSell: structureSell,
      biasIsBuy: bias == MarketBias.buy,
      ema50: ema50,
      ema200: ema200,
      indicators: {'rsi$rsiPeriod': rsi},
      entryCandles: m1.isNotEmpty ? [m1.length - 1] : [],
      structurePoints: const [],
      conditionsMet: reasonsOk,
      reasonsFailed: reasonsNo,
      stopLoss: sl,
      takeProfit: tp,
    );
  }

  // =====================================================
  // ATR (PUBLIC METHOD - FIXED)
  // =====================================================

  double calcATR(List<Candle> candles, int period) {
    if (candles.length < period + 1) return 0.0;

    double sum = 0;

    for (int i = candles.length - period; i < candles.length; i++) {
      final high = candles[i].high;
      final low = candles[i].low;
      final prevClose = candles[i - 1].close;

      final tr1 = high - low;
      final tr2 = (high - prevClose).abs();
      final tr3 = (low - prevClose).abs();

      sum += max(tr1, max(tr2, tr3));
    }

    return sum / period;
  }

  double _atrSL(List<Candle> candles, MarketBias bias) {
    if (candles.length < atrPeriod + 1) return _stopLoss(candles, bias);

    final atr = calcATR(candles, atrPeriod);
    final entry = candles.last.close;

    if (bias == MarketBias.buy) return entry - atr;
    if (bias == MarketBias.sell) return entry + atr;

    return 0.0;
  }

  double _atrTP(double entry, double sl, MarketBias bias, double rr) {
    final risk = (entry - sl).abs();

    if (risk == 0) return 0;

    return bias == MarketBias.buy
        ? entry + risk * rr
        : entry - risk * rr;
  }

  // =====================================================
  // INDICATORS
  // =====================================================

  double _calcRSI(List<Candle> c, int period) {
    if (c.length < period + 1) return 50.0;

    double gain = 0;
    double loss = 0;

    for (int i = c.length - period; i < c.length; i++) {
      final diff = c[i].close - c[i - 1].close;

      if (diff > 0) gain += diff;
      if (diff < 0) loss += -diff;
    }

    if (loss == 0) return 100;

    final rs = gain / loss;

    return 100 - (100 / (1 + rs));
  }

  List<double> _calcEMA(List<Candle> c, int period) {
    if (c.length < period) return [];

    double sma = 0;

    for (int i = c.length - period; i < c.length; i++) {
      sma += c[i].close;
    }

    sma /= period;

    final k = 2 / (period + 1);

    double ema = sma;

    final out = <double>[ema];

    for (int i = c.length - period + 1; i < c.length; i++) {
      ema = c[i].close * k + ema * (1 - k);
      out.add(ema);
    }

    return out;
  }

  // =====================================================
  // STRUCTURE
  // =====================================================

  MarketBias _detectStructure(List<Candle> c) {
    if (c.length < 10) return MarketBias.none;

    final h1 = c[c.length - 1].high;
    final h2 = c[c.length - 5].high;
    final h3 = c[c.length - 10].high;

    final l1 = c[c.length - 1].low;
    final l2 = c[c.length - 5].low;
    final l3 = c[c.length - 10].low;

    if (h1 > h2 && h2 > h3 && l1 > l2 && l2 > l3) {
      return MarketBias.buy;
    }

    if (l1 < l2 && l2 < l3 && h1 < h2 && h2 < h3) {
      return MarketBias.sell;
    }

    return MarketBias.none;
  }

  EntryConfirmation _confirmation(List<Candle> c, MarketBias bias) {
    if (c.length < 2) return EntryConfirmation.none;

    final last = c.last;
    final prev = c[c.length - 2];

    final body = (last.close - last.open).abs();

    final upperWick = last.high - max(last.close, last.open);
    final lowerWick = min(last.close, last.open) - last.low;

    final bullishEngulf = last.close > prev.high && last.close > last.open;
    final bearishEngulf = last.close < prev.low && last.close < last.open;

    final bullishPin = lowerWick > body * 2;
    final bearishPin = upperWick > body * 2;

    if (bias == MarketBias.buy && (bullishEngulf || bullishPin)) {
      return EntryConfirmation.bullish;
    }

    if (bias == MarketBias.sell && (bearishEngulf || bearishPin)) {
      return EntryConfirmation.bearish;
    }

    return EntryConfirmation.none;
  }

  // =====================================================
  // RISK MANAGEMENT
  // =====================================================

  double _stopLoss(List<Candle> c, MarketBias bias) {
    if (c.length < 2) return 0;

    if (bias == MarketBias.buy) {
      return c[c.length - 2].low;
    }

    if (bias == MarketBias.sell) {
      return c[c.length - 2].high;
    }

    return 0;
  }

  double _takeProfit(double entry, double sl, MarketBias bias, double rr) {
    final risk = (entry - sl).abs();

    if (risk == 0) return 0;

    return bias == MarketBias.buy
        ? entry + risk * rr
        : entry - risk * rr;
  }

  bool _checkRR(double entry, double sl, double tp) {
    if (entry == 0 || sl == 0 || tp == 0) return false;

    final risk = (entry - sl).abs();
    final reward = (tp - entry).abs();

    if (risk == 0) return false;

    return reward / risk >= defaultRR;
  }

  bool _checkSession() {
    final now = DateTime.now().toUtc().add(timezoneOffset);

    return now.hour >= sessionStartHour && now.hour <= sessionEndHour;
  }

  // =====================================================
  // CANDLE ENGINE
  // =====================================================

  int _parseEpoch(dynamic epochInput) {
    if (epochInput is int) return epochInput;

    if (epochInput is String) {
      try {
        return DateTime.parse(epochInput).millisecondsSinceEpoch ~/ 1000;
      } catch (_) {}
    }

    return 0;
  }

  List<Candle> _addTickToCandles(
      List<Candle> list, double price, int epoch,
      {required int timeframe}) {
    final bucket = _bucket(epoch, timeframe);

    if (list.isEmpty || list.last.epoch != bucket) {
      final open = list.isNotEmpty ? list.last.close : price;

      list.add(
        Candle(
          epoch: bucket,
          open: open,
          close: price,
          high: price,
          low: price,
          volume: 1,
          time: DateTime.fromMillisecondsSinceEpoch(bucket * 1000),
        ),
      );
    } else {
      final last = list.last;

      list[list.length - 1] = last.copyWith(
        close: price,
        high: max(last.high, price),
        low: min(last.low, price),
        volume: last.volume + 1,
      );
    }

    return list;
  }

  List<Candle> _aggregate(List<Candle> candles,
      {required int timeframeMinutes}) {
    final out = <Candle>[];

    for (final c in candles) {
      _addTickToCandles(out, c.close, c.epoch,
          timeframe: timeframeMinutes);
    }

    return out;
  }

  int _bucket(int epoch, int timeframe) {
    return (epoch ~/ (timeframe * 60)) * (timeframe * 60);
  }

  // =====================================================
  // UTILITIES
  // =====================================================

  List<Candle> _sanitize(List<Candle> candles) {
    final map = <int, Candle>{};

    for (final c in candles) {
      map[c.epoch] = c;
    }

    final out = map.values.toList();
    out.sort((a, b) => a.epoch.compareTo(b.epoch));

    return out;
  }

  String _normalize(String p) {
    p = p.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');

    p = p.replaceFirst(RegExp(r'^(FRXFRX)+'), 'FRX');

    if (!p.startsWith('FRX')) {
      p = 'FRX$p';
    }

    return p;
  }

  void _pruneCandles(String pair, int timeframe) {
    final list = _getCandlesByTimeframe(pair, timeframe);

    if (list.length > maxCandlesStored) {
      list.removeRange(0, list.length - maxCandlesStored);
    }
  }

  List<Candle> _getCandlesByTimeframe(String pair, int timeframe) {
    switch (timeframe) {
      case 1:
        return _candlesM1[pair] ?? [];
      case 5:
        return _candlesM5[pair] ?? [];
      case 15:
        return _candlesM15[pair] ?? [];
      case 30:
        return _candlesM30[pair] ?? [];
      default:
        return _candlesM1[pair] ?? [];
    }
  }
}