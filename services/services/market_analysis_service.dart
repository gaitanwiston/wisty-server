import 'candle.dart';

class MarketAnalysisResult {
  final String symbol;

  // ================= Candles =================
  final List<Candle> candles; // M1
  final List<Candle> candlesM5;
  final List<Candle> candlesM15;
  final List<Candle> candlesM30;
  final List<Candle> candlesH1;

  // ================= NEW CORE (v13) =================
  final String direction; // long / short / neutral
  final String analysisDirection;
  final String stableDirection;

  final double probabilityLong;
  final double probabilityShort;
  final double confidence;

  final double lastPrice;
  final double forecastPrice;

  final DateTime timestamp;

  final double pipTarget;

  final bool volumeConfirmed;

  final double rsi14;
  final double ema20Value;
  final double ema50Value;
  final double ema200Value;
  final double macd;
  final double macdHist;
  final double atr;

  final List<double> probabilityLongHistory;
  final List<double> probabilityShortHistory;

  final List<String> reasons;

  final String structure; // trend / range / neutral

  // ================= OLD SYSTEM (COMPATIBILITY) =================
  final bool structureValid;
  final bool emaValid;
  final bool rsiValid;
  final bool confirmationValid;
  final bool filtersValid;

  final bool canBuy;
  final bool canSell;
  final bool structureBuy;
  final bool structureSell;
  final bool biasIsBuy;

  final List<double> ema50;
  final List<double> ema200;
  final Map<String, double> indicators;

  final List<int> entryCandles;
  final List<int> structurePoints;

  final List<String> conditionsMet;
  final List<String> reasonsFailed;

  final double stopLoss;
  final double takeProfit;

  // ================= CONSTRUCTOR =================
  MarketAnalysisResult({
    required this.symbol,
    required this.candles,

    List<Candle>? candlesM5,
    List<Candle>? candlesM15,
    List<Candle>? candlesM30,
    List<Candle>? candlesH1,

    // NEW
    this.direction = 'neutral',
    this.analysisDirection = 'neutral',
    this.stableDirection = 'neutral',

    this.probabilityLong = 0,
    this.probabilityShort = 0,
    this.confidence = 0,

    this.lastPrice = 0,
    this.forecastPrice = 0,

    DateTime? timestamp,

    this.pipTarget = 0,

    this.volumeConfirmed = false,

    this.rsi14 = 50,
    this.ema20Value = 0,
    this.ema50Value = 0,
    this.ema200Value = 0,
    this.macd = 0,
    this.macdHist = 0,
    this.atr = 0,

    List<double>? probabilityLongHistory,
    List<double>? probabilityShortHistory,

    List<String>? reasons,

    this.structure = 'neutral',

    // OLD
    this.structureValid = false,
    this.emaValid = false,
    this.rsiValid = false,
    this.confirmationValid = false,
    this.filtersValid = false,

    bool? canBuy,
    bool? canSell,
    this.structureBuy = true,
    this.structureSell = true,
    bool? biasIsBuy,

    List<double>? ema50,
    List<double>? ema200,
    Map<String, double>? indicators,

    List<int>? entryCandles,
    List<int>? structurePoints,

    List<String>? conditionsMet,
    List<String>? reasonsFailed,

    double? stopLoss,
    double? takeProfit,
  })  : candlesM5 = candlesM5 ?? [],
        candlesM15 = candlesM15 ?? [],
        candlesM30 = candlesM30 ?? [],
        candlesH1 = candlesH1 ?? [],

        probabilityLongHistory = probabilityLongHistory ?? [],
        probabilityShortHistory = probabilityShortHistory ?? [],

        reasons = reasons ?? [],

        ema50 = ema50 ?? [],
        ema200 = ema200 ?? [],
        indicators = indicators ?? {},

        entryCandles = entryCandles ?? [],
        structurePoints = structurePoints ?? [],

        conditionsMet = conditionsMet ?? [],
        reasonsFailed = reasonsFailed ?? [],

        // 🔥 AUTO-CALCULATED COMPATIBILITY
        canBuy = canBuy ?? (direction == 'long'),
        canSell = canSell ?? (direction == 'short'),
        biasIsBuy = biasIsBuy ?? (direction != 'short'),

        stopLoss = stopLoss ?? _defaultSL(direction, candles, atr),
        takeProfit = takeProfit ?? _defaultTP(direction, candles, atr),

        timestamp = timestamp ?? DateTime.now();

  // ================= DEFAULT SL/TP =================
  static double _defaultSL(String direction, List<Candle> candles, double atr) {
    if (candles.isEmpty) return 0.0;
    final price = candles.last.close;

    if (direction == 'long') return price - (atr * 2);
    if (direction == 'short') return price + (atr * 2);

    return 0.0;
  }

  static double _defaultTP(String direction, List<Candle> candles, double atr) {
    if (candles.isEmpty) return 0.0;
    final price = candles.last.close;

    if (direction == 'long') return price + (atr * 3);
    if (direction == 'short') return price - (atr * 3);

    return 0.0;
  }

  // ================= EMPTY =================
  factory MarketAnalysisResult.empty(String symbol) {
    return MarketAnalysisResult(
      symbol: symbol,
      candles: [],
    );
  }

  // ================= DEBUG =================
  @override
  String toString() {
    return '''
MarketAnalysisResult(
  symbol: $symbol,
  direction: $direction,
  confidence: ${(confidence * 100).toStringAsFixed(1)}%,
  probL: ${probabilityLong.toStringAsFixed(1)},
  probS: ${probabilityShort.toStringAsFixed(1)},
  canBuy: $canBuy,
  canSell: $canSell,
  structure: $structure,
  SL: $stopLoss,
  TP: $takeProfit
)
''';
  }
}