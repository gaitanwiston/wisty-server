// ======================= services/deriv_service.dart (PRO VERSION BORESHA) =======================
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/candle.dart' as model;

/// ================= CONFIG =================
const String derivToken = "5Q0tS24UGTwKvDX";
const int derivAppId = 90453;

class DerivService {
  /// ================= SINGLETON =================
  static final DerivService instance = DerivService._internal();
  factory DerivService() => instance;
  DerivService._internal();

  WebSocketChannel? _channel;
  StreamSubscription? _wsSub;

  bool _authorized = false;
  bool _connected = false;

  final StreamController<Map<String, dynamic>> _controller =
      StreamController.broadcast();
  Stream<Map<String, dynamic>> get stream => _controller.stream;

  final Map<String, List<model.Candle>> _candles = {};
  final Set<String> _subscribed = {};
  final Map<String, String> _symbolMap = {}; // lowercase keys -> actual symbol

  final Map<String, Map<String, dynamic>> openTrades = {};
  final Map<String, StreamController<Map<String, dynamic>>> _contractStreams =
      {};

  String? _token;
  double _cachedBalance = 0.0;

  bool get isConnected => _authorized && _connected;
  double get cachedBalance => _cachedBalance;

  /// ================= CONNECT =================
  Future<void> connect([String? token]) async {
    if (_connected) return;

    _token = token ?? derivToken;
    final uri =
        Uri.parse("wss://ws.derivws.com/websockets/v3?app_id=$derivAppId");

    print("🔌 Connecting to Deriv...");
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
          print("⚠ WS parse error: $e");
        }
      },
      onError: (err) {
        print("⚠ WS error: $err");
        _reconnect();
      },
      onDone: () {
        print("⚠ WS closed");
        _reconnect();
      },
    );

    _send({"authorize": _token});
  }

  /// ================= HANDLE WS MESSAGES =================
  void _handleMessage(Map<String, dynamic> data) {
    final type = data['msg_type'];
    switch (type) {
      case 'authorize':
        _authorized = true;
        print("✅ Authorized");
        _send({"balance": 1});
        _send({"active_symbols": "brief", "product_type": "basic"});
        break;

      case 'balance':
      case 'balance_response':
        final balanceData = data['balance'] ?? data['balance_response'];
        if (balanceData != null && balanceData['balance'] != null) {
          _cachedBalance =
              double.tryParse(balanceData['balance'].toString()) ?? 0.0;
          print("💰 Cached balance updated: $_cachedBalance");
        }
        break;

      case 'active_symbols':
        final raw = data['active_symbols'];
        if (raw is List) {
          _symbolMap.clear();
          for (final e in raw) {
            if (e['market'] == 'forex') {
              final symbol = e['symbol'];
              _symbolMap[symbol.toLowerCase()] = symbol;
            }
          }
          print("📌 Market pairs loaded: ${_symbolMap.values.join(', ')}");
          for (var pair in _symbolMap.keys) {
            subscribe(pair);
          }
        }
        break;

      case 'candles':
        final symbolRaw = (data['echo_req']?['ticks_history'] ?? "").toLowerCase();
        final symbol = _symbolMap[symbolRaw] ?? symbolRaw;
        final candles = data['candles'] ?? [];
        final list = <model.Candle>[];

        for (final c in candles) {
          list.add(model.Candle(
            epoch: int.tryParse(c['epoch'].toString()) ?? 0,
            open: double.tryParse(c['open'].toString()) ?? 0,
            close: double.tryParse(c['close'].toString()) ?? 0,
            high: double.tryParse(c['high'].toString()) ?? 0,
            low: double.tryParse(c['low'].toString()) ?? 0,
            volume: double.tryParse(c['volume'].toString()) ?? 0,
          ));
        }

        _candles[symbol] = list;
        print("✅ Candles loaded: ${list.length} for $symbol");
        break;

      case 'tick':
        final tick = data['tick'];
        if (tick != null) {
          final symbolRaw = tick['symbol'].toLowerCase();
          final symbol = _symbolMap[symbolRaw] ?? symbolRaw;
          final price = double.tryParse(tick['quote'].toString()) ?? 0.0;
          final epoch = int.tryParse(tick['epoch'].toString()) ?? 0;
          _updateCandles(symbol, price, epoch);

          for (var ctrl in _contractStreams.values) {
            ctrl.add({"price": price, "epoch": epoch});
          }
        }
        break;
    }
  }

  /// ================= SUBSCRIBE =================
  Future<void> subscribe(String symbol) async {
    if (!_connected) await connect();
    if (_subscribed.contains(symbol)) return;

    _subscribed.add(symbol);

    await _sendAndWait("candles", {
      "ticks_history": _symbolMap[symbol.toLowerCase()] ?? symbol,
      "style": "candles",
      "granularity": 60,
      "count": 5000,
      "end": "latest",
    });

    _send({"ticks": _symbolMap[symbol.toLowerCase()] ?? symbol, "subscribe": 1});
    print("📡 Subscribed: $symbol ✅");
  }

  /// ================= CANDLES =================
  List<model.Candle> getCandles(String pair) {
    final actual = _symbolMap[pair.toLowerCase()] ?? pair;
    return _candles[actual] ?? [];
  }

  Future<List<model.Candle>> getCandlesWithTF(String pair,
      {int timeframe = 1}) async {
    return getCandles(pair);
  }

  void _updateCandles(String symbol, double price, int epoch) {
    final list = _candles.putIfAbsent(symbol, () => []);
    final bucket = (epoch ~/ 60) * 60;

    if (list.isEmpty || list.last.epoch != bucket) {
      final open = list.isNotEmpty ? list.last.close : price;
      list.add(model.Candle(
        epoch: bucket,
        open: open,
        close: price,
        high: max(open, price),
        low: min(open, price),
        volume: 1,
      ));
    } else {
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

    if (list.length > 10000) {
      list.removeRange(0, list.length - 10000);
    }
  }

  /// ================= BALANCE =================
  Future<double> getBalance({int waitMs = 5000}) async {
    final start = DateTime.now();
    while (_cachedBalance == 0.0 &&
        DateTime.now().difference(start).inMilliseconds < waitMs) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return _cachedBalance;
  }


  /// ================= TRADE (FULL PRO VERSION) =================
  Future<String?> placeTrade(String pair, bool isBuy,
      {double stake = 10, double multiplier = 50}) async {
    final actual = _symbolMap[pair.toLowerCase()] ?? pair;

    // 1️⃣ Request Proposal
    final proposalResp = await _sendAndWait("proposal", {
      "proposal": 1,
      "amount": stake,
      "basis": "stake",
      "contract_type": isBuy ? "MULTUP" : "MULTDOWN",
      "currency": "USD",
      "symbol": actual,
      "multiplier": multiplier,
    });

    final proposal = proposalResp['proposal'];
    if (proposal == null) {
      print("❌ Proposal failed for $pair");
      return null;
    }

    final proposalId = proposal['id'];
    final proposalPrice = proposal['display_value'] ??
        proposal['ask_price'] ??
        stake; // fallback

    // 2️⃣ Buy Contract with Proposal Price
    final buyResp = await _sendAndWait("buy", {
      "buy": proposalId,
      "price": proposalPrice,
    });

    final contractId = buyResp['buy']?['contract_id']?.toString();

    if (contractId != null) {
      openTrades[contractId] = {
        "pair": pair,
        "stake": stake,
        "direction": isBuy ? "BUY" : "SELL",
      };
      print("✅ Trade placed: $contractId");
    } else {
      print("❌ Buy failed for $pair, proposal price used: $proposalPrice");
    }

    return contractId;
  }

  Future<double> getLastPrice(String pair) async {
    final candles = getCandles(pair);
    if (candles.isNotEmpty) return candles.last.close;
    return 0.0;
  }

  /// ================= CONTRACT STREAM =================
  void subscribeContract(
      String contractId,
      Function(Map<String, dynamic>) onUpdate) {
    final ctrl = _contractStreams.putIfAbsent(
        contractId,
        () => StreamController<Map<String, dynamic>>.broadcast());
    ctrl.stream.listen(onUpdate);
  }

  Future<void> closeTradeById(String contractId) async {
    _contractStreams[contractId]?.close();
    _contractStreams.remove(contractId);
    openTrades.remove(contractId);
  }

  Future<List<String>> getMarketPairs() async {
    return _symbolMap.values.toList();
  }

  /// ================= SEND HELPERS =================
  void _send(Map<String, dynamic> data) {
    _channel?.sink.add(jsonEncode(data));
  }

  Future<Map<String, dynamic>> _sendAndWait(
      String type, Map<String, dynamic> data,
      {int timeout = 15}) async {
    final completer = Completer<Map<String, dynamic>>();
    late StreamSubscription sub;

    sub = stream.listen((event) {
      if (event['msg_type'] == type && !completer.isCompleted) {
        completer.complete(event);
        sub.cancel();
      }
    });

    _send(data);

    Future.delayed(Duration(seconds: timeout), () {
      if (!completer.isCompleted) {
        completer.complete({});
        sub.cancel();
      }
    });

    return completer.future;
  }

  /// ================= RECONNECT =================
  Future<void> _reconnect() async {
    print("🔁 Reconnecting...");
    _connected = false;
    _authorized = false;

    await _channel?.sink.close();
    await Future.delayed(const Duration(seconds: 2));

    if (_token != null) {
      await connect(_token!);
      for (var s in _subscribed) {
        subscribe(s);
      }
    }
  }
}