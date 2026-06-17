import '../models/trade_signal.dart';
import '../models/confirmation_result.dart';
import 'market_analysis_service.dart';

class SecondConfirmationService {
  SecondConfirmationService._();
  static final instance =
      SecondConfirmationService._();

  Future<ConfirmationResult> verify(
    TradeSignal signal,
  ) async {
    final latest =
        MarketAnalysisService.instance
            .latestFor(signal.symbol);

    if (latest == null) {
      return ConfirmationResult(
        approved: false,
        reason: "NO_ANALYSIS",
      );
    }

    final server2Buy = latest.canBuy;
    final server2Sell = latest.canSell;

    if (signal.direction == "BUY" &&
        !server2Buy) {
      return ConfirmationResult(
        approved: false,
        reason: "BUY_MISMATCH",
      );
    }

    if (signal.direction == "SELL" &&
        !server2Sell) {
      return ConfirmationResult(
        approved: false,
        reason: "SELL_MISMATCH",
      );
    }

    final confidence =
        (latest.indicators["confidence"] ?? 0)
            .toDouble();

    if (confidence < 80) {
      return ConfirmationResult(
        approved: false,
        reason: "LOW_CONFIDENCE",
      );
    }

    return ConfirmationResult(
      approved: true,
      reason: "CONFIRMED",
    );
  }
}