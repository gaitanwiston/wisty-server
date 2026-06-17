class IncomingSignal {
  final String pair;
  final String direction;

  final double confidence;
  final double buyScore;
  final double sellScore;

  final String w1Bias;
  final String d1Bias;

  final bool trendAligned;

  final int timestamp;

  IncomingSignal({
    required this.pair,
    required this.direction,
    required this.confidence,
    required this.buyScore,
    required this.sellScore,
    required this.w1Bias,
    required this.d1Bias,
    required this.trendAligned,
    required this.timestamp,
  });

  factory IncomingSignal.fromJson(
    Map<String, dynamic> json,
  ) {
    return IncomingSignal(
      pair: json['pair'] ?? '',
      direction: json['direction'] ?? '',
      confidence:
          (json['confidence'] ?? 0).toDouble(),
      buyScore:
          (json['buyScore'] ?? 0).toDouble(),
      sellScore:
          (json['sellScore'] ?? 0).toDouble(),
      w1Bias: json['w1Bias'] ?? '',
      d1Bias: json['d1Bias'] ?? '',
      trendAligned:
          json['trendAligned'] ?? false,
      timestamp: json['timestamp'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'pair': pair,
      'direction': direction,
      'confidence': confidence,
      'buyScore': buyScore,
      'sellScore': sellScore,
      'w1Bias': w1Bias,
      'd1Bias': d1Bias,
      'trendAligned': trendAligned,
      'timestamp': timestamp,
    };
  }
}