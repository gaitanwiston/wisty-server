// ======================= routes/trades.dart (ULTRA STABLE VERSION) =======================
import 'dart:async';
import 'dart:math';

import 'package:dart_frog/dart_frog.dart';

import '../services/deriv_service.dart';

final Map<String, Map<String, ActiveTrade>> _userTrades = {};
final Map<String, bool> _tradeLocks = {};
final Map<String, StreamSubscription?> _subscriptions = {};

class ActiveTrade {
  final bool buy;
  final double stake;
  final String contractId;
  final String pair;
  final String userId;

  double entryPrice;
  double sl;
  double tp;
  double currentPrice;

  bool breakeven = false;
  bool partialClosed = false;
  bool closed = false;

  DateTime openedAt;
  DateTime lastTick;

  ActiveTrade({
    required this.buy,
    required this.stake,
    required this.contractId,
    required this.pair,
    required this.userId,
    required this.entryPrice,
    required this.sl,
    required this.tp,
    this.currentPrice = 0,
    DateTime? openedAt,
    DateTime? lastTick,
  })  : openedAt = openedAt ?? DateTime.now(),
        lastTick = lastTick ?? DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'pair': pair,
      'buy': buy,
      'stake': stake,
      'entry': entryPrice,
      'sl': sl,
      'tp': tp,
      'price': currentPrice,
      'breakeven': breakeven,
      'partial': partialClosed,
      'closed': closed,
      'contractId': contractId,
      'openedAt': openedAt.toIso8601String(),
      'lastTick': lastTick.toIso8601String(),
    };
  }
}

/// ================= ROUTE =================
Future<Response> onRequest(RequestContext context) async {
  final userId = context.request.headers['x-user-id'] ?? 'guest';

  print('\n==================== REQUEST ====================');
  print('👤 USER: $userId');
  print('📡 METHOD: ${context.request.method}');
  print('================================================\n');

  switch (context.request.method) {
    case HttpMethod.post:
      return _openTrade(context, userId);

    case HttpMethod.get:
      return _getActiveTrades(userId);

    case HttpMethod.delete:
      return _closeTrade(context, userId);

    default:
      return Response(statusCode: 405);
  }
}

/// ================= NORMALIZE =================
String _normalizePair(String p) {
  p = p.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');

  if (!p.startsWith('FRX')) {
    return 'FRX$p';
  }

  return p;
}

/// ================= DERIV SYMBOL =================
String _toDerivSymbol(String pair) {
  if (pair.startsWith('FRX')) {
    return 'frx${pair.substring(3)}';
  }

  return pair.toLowerCase();
}

/// ================= OPEN TRADE =================
Future<Response> _openTrade(
  RequestContext context,
  String userId,
) async {
  try {
    final body = await context.request.json();

    print('📥 CLIENT DATA: $body');

    final pairRaw = (body['pair'] as String?)?.trim();
    final action = (body['action'] as String?)?.toUpperCase();
    final stake = (body['stake'] as num?)?.toDouble();

    if (pairRaw == null || action == null || stake == null) {
      return Response.json(
        statusCode: 400,
        body: {
          'success': false,
          'error': 'Missing params',
        },
      );
    }

    if (stake <= 0) {
      return Response.json(
        statusCode: 400,
        body: {
          'success': false,
          'error': 'Invalid stake',
        },
      );
    }

    if (action != 'BUY' && action != 'SELL') {
      return Response.json(
        statusCode: 400,
        body: {
          'success': false,
          'error': 'Invalid action',
        },
      );
    }

    final pair = _normalizePair(pairRaw);
    final derivSymbol = _toDerivSymbol(pair);

    final trades = _userTrades.putIfAbsent(
      userId,
      () => {},
    );

    final lockKey = '$userId:$pair';

    /// ================= LOCK =================
    if (_tradeLocks[lockKey] == true) {
      return Response.json(
        statusCode: 429,
        body: {
          'success': false,
          'error': 'Trade locked',
        },
      );
    }

    _tradeLocks[lockKey] = true;

    try {
      /// ================= ACTIVE CHECK =================
      if (trades.containsKey(pair)) {
        return Response.json(
          statusCode: 400,
          body: {
            'success': false,
            'error': 'Trade already active',
          },
        );
      }

      final deriv = DerivService.instance;

      /// ================= CONNECT =================
      print('🔌 CONNECTING DERIV...');

      if (!deriv.isConnected) {
        await deriv.connect();
      }

      print('✅ DERIV CONNECTED');

      /// ================= ENTRY PRICE =================
      double entryPrice = 0;

      try {
        entryPrice = await deriv
            .getLastPrice(derivSymbol)
            .timeout(const Duration(seconds: 10));

        print('📊 ENTRY PRICE: $entryPrice');
      } catch (e) {
        print('⚠ ENTRY FETCH ERROR: $e');

        return Response.json(
          statusCode: 500,
          body: {
            'success': false,
            'error': 'Failed to fetch market price',
          },
        );
      }

      /// ================= ATR =================
      double atr = 0.002;

      try {
        final candles = await deriv
            .getCandlesWithTF(derivSymbol)
            .timeout(const Duration(seconds: 15));

        atr = max(_calcATR(candles, 14), 0.0005);

        print('📈 ATR: $atr');
      } catch (e) {
        print('⚠ ATR ERROR: $e');
      }

      /// ================= PLACE TRADE =================
      String? contractId;

      try {
        print('📤 PLACING TRADE...');
        print('➡ SYMBOL: $derivSymbol');
        print('➡ ACTION: $action');
        print('➡ STAKE: $stake');

        contractId = await deriv.placeTrade(
          derivSymbol,
          action == 'BUY',
          stake: stake,
        ).timeout(const Duration(seconds: 20));

        print('✅ CONTRACT ID: $contractId');
      } catch (e) {
        print('❌ PLACE TRADE ERROR: $e');

        return Response.json(
          statusCode: 500,
          body: {
            'success': false,
            'error': 'Deriv trade failed',
          },
        );
      }

      if (contractId == null || contractId.isEmpty) {
        return Response.json(
          statusCode: 500,
          body: {
            'success': false,
            'error': 'Invalid contract id',
          },
        );
      }

      /// ================= RISK =================
      final risk = max(atr, 0.0005);

      final sl = action == 'BUY'
          ? entryPrice - risk
          : entryPrice + risk;

      final tp = action == 'BUY'
          ? entryPrice + (risk * 3)
          : entryPrice - (risk * 3);

      /// ================= CREATE TRADE =================
      final trade = ActiveTrade(
        buy: action == 'BUY',
        stake: stake,
        contractId: contractId,
        pair: pair,
        userId: userId,
        entryPrice: entryPrice,
        sl: sl,
        tp: tp,
        currentPrice: entryPrice,
      );

      trades[pair] = trade;

      print('🚀 TRADE STORED');

      /// ================= SAFE CLOSE =================
      Future<void> safeClose({
        required String reason,
      }) async {
        if (trade.closed) return;

        print('🔴 CLOSING TRADE...');
        print('📌 REASON: $reason');

        trade.closed = true;

        try {
          await deriv.closeTradeById(contractId!).timeout(
            const Duration(seconds: 10),
          );

          print('✅ DERIV CLOSE SUCCESS');
        } catch (e) {
          print('⚠ CLOSE ERROR: $e');
        }

        try {
          await _subscriptions[contractId]?.cancel();
        } catch (_) {}

        _subscriptions.remove(contractId);

        trades.remove(pair);

        _tradeLocks.remove(lockKey);

        print('✅ TRADE REMOVED');
      }

      /// ================= SUBSCRIBE =================
      final sub = deriv.subscribeContract(
        contractId,
        (tick) async {
          if (trade.closed) return;

          try {
            final raw =
                tick['price'] ??
                tick['quote'] ??
                tick['bid'] ??
                0;

            final price = raw is num
                ? raw.toDouble()
                : double.tryParse('$raw') ?? 0;

            if (price <= 0) return;

            trade.currentPrice = price;
            trade.lastTick = DateTime.now();

            print('📡 $pair → $price');

            final currentRisk = max(
              (trade.entryPrice - trade.sl).abs(),
              0.00001,
            );

            final rr = (price - trade.entryPrice).abs() /
                currentRisk;

            /// ================= BREAKEVEN =================
            if (!trade.breakeven && rr >= 1) {
              trade.sl = trade.entryPrice;
              trade.breakeven = true;

              print('⚖ BREAKEVEN ACTIVATED');
            }

            /// ================= PARTIAL =================
            if (!trade.partialClosed && rr >= 2) {
              trade.partialClosed = true;

              print('💰 PARTIAL TARGET HIT');
            }

            /// ================= TRAILING =================
            if (rr >= 1.5) {
              final newSl = trade.buy
                  ? price - (currentRisk * 0.5)
                  : price + (currentRisk * 0.5);

              if (trade.buy && newSl > trade.sl) {
                trade.sl = newSl;
              }

              if (!trade.buy && newSl < trade.sl) {
                trade.sl = newSl;
              }
            }

            /// ================= EXIT =================
            final tpHit = trade.buy
                ? price >= trade.tp
                : price <= trade.tp;

            final slHit = trade.buy
                ? price <= trade.sl
                : price >= trade.sl;

            if (tpHit) {
              await safeClose(reason: 'TP HIT');
            }

            if (slHit) {
              await safeClose(reason: 'SL HIT');
            }
          } catch (e) {
            print('⚠ TICK ERROR: $e');
          }
        },
      );

      _subscriptions[contractId] = sub;

      return Response.json(
        body: {
          'success': true,
          'pair': pair,
          'action': action,
          'entry': entryPrice,
          'sl': sl,
          'tp': tp,
          'contractId': contractId,
        },
      );
    } finally {
      _tradeLocks.remove(lockKey);
    }
  } catch (e) {
    print('❌ SERVER ERROR: $e');

    return Response.json(
      statusCode: 500,
      body: {
        'success': false,
        'error': '$e',
      },
    );
  }
}

/// ================= MANUAL CLOSE =================
Future<Response> _closeTrade(
  RequestContext context,
  String userId,
) async {
  try {
    final body = await context.request.json();

    final pairRaw = body['pair']?.toString();

    if (pairRaw == null) {
      return Response.json(
        statusCode: 400,
        body: {
          'success': false,
          'error': 'Pair required',
        },
      );
    }

    final pair = _normalizePair(pairRaw);

    final trades = _userTrades[userId];

    if (trades == null || !trades.containsKey(pair)) {
      return Response.json(
        statusCode: 404,
        body: {
          'success': false,
          'error': 'Trade not found',
        },
      );
    }

    final trade = trades[pair]!;

    if (trade.closed) {
      return Response.json(
        statusCode: 400,
        body: {
          'success': false,
          'error': 'Trade already closed',
        },
      );
    }

    trade.closed = true;

    try {
      await DerivService.instance.closeTradeById(
        trade.contractId,
      );
    } catch (e) {
      print('⚠ MANUAL CLOSE ERROR: $e');
    }

    try {
      await _subscriptions[trade.contractId]?.cancel();
    } catch (_) {}

    _subscriptions.remove(trade.contractId);

    trades.remove(pair);

    return Response.json(
      body: {
        'success': true,
        'message': 'Trade closed',
      },
    );
  } catch (e) {
    return Response.json(
      statusCode: 500,
      body: {
        'success': false,
        'error': '$e',
      },
    );
  }
}

/// ================= GET ACTIVE =================
Future<Response> _getActiveTrades(String userId) async {
  final trades = _userTrades[userId] ?? {};

  print('📊 ACTIVE TRADES: ${trades.length}');

  return Response.json(
    body: {
      'success': true,
      'count': trades.length,
      'trades': trades.values.map((t) => t.toJson()).toList(),
    },
  );
}

/// ================= ATR =================
double _calcATR(
  List candles,
  int period,
) {
  if (candles.length < period + 1) {
    return 0.002;
  }

  double atr = 0;

  for (int i = 1; i <= period; i++) {
    final c = candles[i];
    final prev = candles[i - 1];

    final high = (c.high as num).toDouble();
    final low = (c.low as num).toDouble();
    final prevClose = (prev.close as num).toDouble();

    final tr = <double>[
      high - low,
      (high - prevClose).abs(),
      (low - prevClose).abs(),
    ].reduce(max);

    atr += tr;
  }

  return atr / period;
}