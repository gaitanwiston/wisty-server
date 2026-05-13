// ======================= services/deriv_service.dart (ULTRA PRO STABLE VERSION) =======================
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/candle.dart' as model;

/// ================= CONFIG =================
const String derivToken =
    "pat_0fccfffc5d1eaace805fb961cd606399a8665f15e6e40da9cdd313a67ac8ec08";

const int derivAppId = 1089;

class DerivService {
  /// ================= SINGLETON =================
  static final DerivService instance = DerivService._internal();

  factory DerivService() => instance;

  DerivService._internal();

  WebSocketChannel? _channel;
  StreamSubscription? _wsSub;

  bool _authorized = false;
  bool _connected = false;
  bool _connecting = false;

  String? _token;

  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get stream => _controller.stream;

  final Map<String, List<model.Candle>> _candles = {};

  final Set<String> _subscribed = {};

  final Map<String, String> _symbolMap = {};

  final Map<String, Map<String, dynamic>> openTrades = {};

  final Map<String, StreamController<Map<String, dynamic>>>
      _contractStreams = {};

  double _cachedBalance = 0.0;

  bool get isConnected => _authorized && _connected;

  double get cachedBalance => _cachedBalance;

  /// ================= CONNECT =================
  Future<void> connect([String? token]) async {
    if (_connected || _connecting) return;

    _connecting = true;

    try {
      _token = token ?? derivToken;

      final uri = Uri.parse(
        'wss://ws.derivws.com/websockets/v3?app_id=$derivAppId',
      );

      print('🔌 Connecting to Deriv...');

      _channel = WebSocketChannel.connect(uri);

      _connected = true;

      _wsSub = _channel!.stream.listen(
        (msg) {
          try {
            final data = jsonDecode(msg);

            if (data is Map<String, dynamic>) {
              _handleMessage(data);

              _controller.add(data);
            }
          } catch (e) {
            print('⚠ WS parse error: $e');
          }
        },
        onError: (e) async {
          print('❌ WS ERROR: $e');

          await _reconnect();
        },
        onDone: () async {
          print('⚠ WS CLOSED');

          await _reconnect();
        },
        cancelOnError: true,
      );

      _send({
        "authorize": _token,
      });

      print('✅ Authorization request sent');
    } catch (e) {
      print('❌ CONNECT ERROR: $e');

      _connected = false;
      _authorized = false;
    } finally {
      _connecting = false;
    }
  }

  /// ================= HANDLE MESSAGE =================
  void _handleMessage(Map<String, dynamic> data) {
    final type = data['msg_type'];

    switch (type) {
      /// ================= AUTHORIZE =================
      case 'authorize':
        _authorized = true;

        print('✅ Authorized');

        _send({"balance": 1});

        _send({
          "active_symbols": "brief",
          "product_type": "basic",
        });

        break;

      /// ================= BALANCE =================
      case 'balance':
      case 'balance_response':
        try {
          final balanceData =
              data['balance'] ?? data['balance_response'];

          if (balanceData != null) {
            _cachedBalance =
                double.tryParse(
                      balanceData['balance'].toString(),
                    ) ??
                    0.0;

            print('💰 BALANCE UPDATED: $_cachedBalance');
          }
        } catch (e) {
          print('⚠ BALANCE ERROR: $e');
        }

        break;

      /// ================= ACTIVE SYMBOLS =================
      case 'active_symbols':
        try {
          final raw = data['active_symbols'];

          if (raw is List) {
            _symbolMap.clear();

            for (final e in raw) {
              if (e['market'] == 'forex') {
                final symbol = e['symbol'];

                _symbolMap[symbol.toLowerCase()] = symbol;
              }
            }

            print(
              '📌 FOREX PAIRS LOADED: ${_symbolMap.length}',
            );

            for (final pair in _symbolMap.keys) {
              subscribe(pair);
            }
          }
        } catch (e) {
          print('⚠ ACTIVE SYMBOL ERROR: $e');
        }

        break;

      /// ================= CANDLES =================
      case 'candles':
        try {
          final symbolRaw =
              (data['echo_req']?['ticks_history'] ?? '')
                  .toString()
                  .toLowerCase();

          final symbol =
              _symbolMap[symbolRaw] ?? symbolRaw;

          final candles = data['candles'] ?? [];

          final list = <model.Candle>[];

          for (final c in candles) {
            list.add(
              model.Candle(
                epoch:
                    int.tryParse(c['epoch'].toString()) ?? 0,
                open:
                    double.tryParse(c['open'].toString()) ??
                        0,
                close:
                    double.tryParse(c['close'].toString()) ??
                        0,
                high:
                    double.tryParse(c['high'].toString()) ??
                        0,
                low:
                    double.tryParse(c['low'].toString()) ??
                        0,
                volume:
                    double.tryParse(
                          c['volume'].toString(),
                        ) ??
                        0,
              ),
            );
          }

          _candles[symbol] = list;

          print(
            '✅ Candles loaded: ${list.length} for $symbol',
          );
        } catch (e) {
          print('⚠ CANDLES ERROR: $e');
        }

        break;

      /// ================= TICK =================
      case 'tick':
        try {
          final tick = data['tick'];

          if (tick == null) return;

          final symbolRaw =
              tick['symbol'].toString().toLowerCase();

          final symbol =
              _symbolMap[symbolRaw] ?? symbolRaw;

          final price =
              double.tryParse(
                    tick['quote'].toString(),
                  ) ??
                  0.0;

          final epoch =
              int.tryParse(tick['epoch'].toString()) ??
                  0;

          if (price <= 0) return;

          _updateCandles(
            symbol,
            price,
            epoch,
          );

          for (final ctrl in _contractStreams.values) {
            if (!ctrl.isClosed) {
              ctrl.add({
                "price": price,
                "epoch": epoch,
                "symbol": symbol,
              });
            }
          }
        } catch (e) {
          print('⚠ TICK ERROR: $e');
        }

        break;
    }
  }

  /// ================= SUBSCRIBE =================
  Future<void> subscribe(String symbol) async {
    try {
      if (!_connected) {
        await connect();
      }

      if (_subscribed.contains(symbol)) {
        return;
      }

      _subscribed.add(symbol);

      final actual =
          _symbolMap[symbol.toLowerCase()] ?? symbol;

      /// candles
      await _sendAndWait(
        'candles',
        {
          "ticks_history": actual,
          "style": "candles",
          "granularity": 60,
          "count": 5000,
          "end": "latest",
        },
      );

      /// live ticks
      _send({
        "ticks": actual,
        "subscribe": 1,
      });

      print('📡 SUBSCRIBED: $actual');
    } catch (e) {
      print('⚠ SUBSCRIBE ERROR: $e');
    }
  }

  /// ================= GET CANDLES =================
  List<model.Candle> getCandles(String pair) {
    final actual =
        _symbolMap[pair.toLowerCase()] ?? pair;

    return _candles[actual] ?? [];
  }

  Future<List<model.Candle>> getCandlesWithTF(
    String pair, {
    int timeframe = 1,
  }) async {
    final actual =
        _symbolMap[pair.toLowerCase()] ?? pair;

    if (!_subscribed.contains(actual.toLowerCase())) {
      await subscribe(actual);
    }

    return getCandles(actual);
  }

  /// ================= UPDATE CANDLES =================
  void _updateCandles(
    String symbol,
    double price,
    int epoch,
  ) {
    final list = _candles.putIfAbsent(
      symbol,
      () => [],
    );

    final bucket = (epoch ~/ 60) * 60;

    /// NEW CANDLE
    if (list.isEmpty || list.last.epoch != bucket) {
      final open =
          list.isNotEmpty ? list.last.close : price;

      list.add(
        model.Candle(
          epoch: bucket,
          open: open,
          close: price,
          high: max(open, price),
          low: min(open, price),
          volume: 1,
        ),
      );
    }

    /// UPDATE EXISTING
    else {
      final last = list.last;

      list[list.length - 1] = model.Candle(
        epoch: last.epoch,
        open: last.open,
        close: price,
        high: max(last.high, price),
        low: min(last.low, price),
        volume: last.volume + 1,
      );
    }

    /// LIMIT
    if (list.length > 10000) {
      list.removeRange(
        0,
        list.length - 10000,
      );
    }
  }

  /// ================= BALANCE =================
  Future<double> getBalance({
    int waitMs = 5000,
  }) async {
    final start = DateTime.now();

    while (_cachedBalance == 0.0 &&
        DateTime.now()
                .difference(start)
                .inMilliseconds <
            waitMs) {
      await Future.delayed(
        const Duration(milliseconds: 100),
      );
    }

    return _cachedBalance;
  }

  /// ================= LAST PRICE =================
  Future<double> getLastPrice(String pair) async {
    final actual =
        _symbolMap[pair.toLowerCase()] ?? pair;

    final candles = _candles[actual] ?? [];

    if (candles.isNotEmpty) {
      return candles.last.close;
    }

    return 0.0;
  }

  /// ================= PLACE TRADE =================
  Future<String?> placeTrade(
    String pair,
    bool isBuy, {
    double stake = 10,
    double multiplier = 100,
  }) async {
    try {
      const validMultipliers = [
        100,
        200,
        300,
        500,
      ];

      if (!validMultipliers.contains(multiplier.toInt())) {
        multiplier = 100;
      }

      final actual =
          _symbolMap[pair.toLowerCase()] ?? pair;

      print(
        '💡 PLACE TRADE -> $actual | BUY: $isBuy | STAKE: $stake',
      );

      /// ================= PROPOSAL =================
      final proposalResp = await _sendAndWait(
        'proposal',
        {
          "proposal": 1,
          "amount": stake,
          "basis": "stake",
          "contract_type":
              isBuy ? "MULTUP" : "MULTDOWN",
          "currency": "USD",
          "symbol": actual,
          "multiplier": multiplier,
        },
      );

      final proposal = proposalResp['proposal'];

      if (proposal == null) {
        print('❌ PROPOSAL FAILED');

        print(proposalResp);

        return null;
      }

      final proposalId = proposal['id'];

      final proposalPrice =
          proposal['display_value'] ??
              proposal['ask_price'] ??
              stake;

      /// ================= BUY =================
      final buyResp = await _sendAndWait(
        'buy',
        {
          "buy": proposalId,
          "price": proposalPrice,
        },
      );

      final contractId =
          buyResp['buy']?['contract_id']
              ?.toString();

      if (contractId != null) {
        openTrades[contractId] = {
          "pair": actual,
          "stake": stake,
          "direction": isBuy ? "BUY" : "SELL",
        };

        print('✅ TRADE OPENED: $contractId');

        return contractId;
      }

      print('❌ BUY FAILED');

      print(buyResp);

      return null;
    } catch (e) {
      print('❌ PLACE TRADE ERROR: $e');

      return null;
    }
  }

  /// ================= SEND + WAIT =================
  Future<Map<String, dynamic>> _sendAndWait(
    String type,
    Map<String, dynamic> data, {
    int timeout = 15,
  }) async {
    final completer =
        Completer<Map<String, dynamic>>();

    late StreamSubscription sub;

    sub = stream.listen((event) {
      if (!completer.isCompleted &&
          event['msg_type'] == type) {
        completer.complete(event);

        sub.cancel();
      }
    });

    print('📤 SEND ($type): $data');

    _send(data);

    Future.delayed(
      Duration(seconds: timeout),
      () {
        if (!completer.isCompleted) {
          print('⏱ TIMEOUT: $type');

          completer.complete({});

          sub.cancel();
        }
      },
    );

    final response = await completer.future;

    print('📥 RESPONSE ($type): $response');

    return response;
  }

  /// ================= CONTRACT SUBSCRIPTION =================
  StreamSubscription subscribeContract(
    String contractId,
    Function(Map<String, dynamic>) onUpdate,
  ) {
    final ctrl = _contractStreams.putIfAbsent(
      contractId,
      () => StreamController<Map<String, dynamic>>.broadcast(),
    );

    final subscription = ctrl.stream.listen(onUpdate);

    print('📡 CONTRACT SUBSCRIBED: $contractId');

    return subscription;
  }

  /// ================= CLOSE TRADE =================
  Future<void> closeTradeById(
    String contractId,
  ) async {
    try {
      final ctrl = _contractStreams[contractId];

      if (ctrl != null && !ctrl.isClosed) {
        await ctrl.close();
      }

      _contractStreams.remove(contractId);

      openTrades.remove(contractId);

      print('✅ TRADE CLOSED: $contractId');
    } catch (e) {
      print('⚠ CLOSE TRADE ERROR: $e');
    }
  }

  /// ================= MARKET PAIRS =================
  Future<List<String>> getMarketPairs() async {
    return _symbolMap.values.toList();
  }

  /// ================= SEND =================
  void _send(Map<String, dynamic> data) {
    try {
      _channel?.sink.add(
        jsonEncode(data),
      );
    } catch (e) {
      print('⚠ SEND ERROR: $e');
    }
  }

  /// ================= RECONNECT =================
  Future<void> _reconnect() async {
    try {
      print('🔁 RECONNECTING...');

      _connected = false;
      _authorized = false;

      await _wsSub?.cancel();

      await _channel?.sink.close();

      await Future.delayed(
        const Duration(seconds: 2),
      );

      if (_token != null) {
        await connect(_token);

        for (final s in _subscribed.toList()) {
          await subscribe(s);
        }
      }
    } catch (e) {
      print('❌ RECONNECT ERROR: $e');
    }
  }

  /// ================= DISPOSE =================
  Future<void> dispose() async {
    try {
      await _wsSub?.cancel();

      await _channel?.sink.close();

      for (final ctrl in _contractStreams.values) {
        await ctrl.close();
      }

      await _controller.close();

      _connected = false;
      _authorized = false;

      print('🛑 DERIV SERVICE DISPOSED');
    } catch (e) {
      print('⚠ DISPOSE ERROR: $e');
    }
  }
}