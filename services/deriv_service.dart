import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/candle.dart' as model;

const String derivToken =
    "pat_0fccfffc5d1eaace805fb961cd606399a8665f15e6e40da9cdd313a67ac8ec08";

const int derivAppId = 1089;

enum TF { m1, h1, h4, d1, w1 }

class DerivService {
  static final DerivService instance = DerivService._internal();
  DerivService._internal();

  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  bool _connected = false;
  bool _auth = false;
  bool _connecting = false;
  bool _reconnecting = false;

  String? _token;

  final StreamController<Map<String, dynamic>> _stream =
      StreamController.broadcast();

  Stream<Map<String, dynamic>> get stream => _stream.stream;

  final Map<String, Map<TF, List<model.Candle>>> _data = {};
  final Set<String> _subscribed = {};
  final List<String> _marketPairs = [];

  final Map<String, double> _balanceCache = {};
  final Map<String, StreamController<Map<String, dynamic>>> _contracts = {};

  bool get isConnected => _connected && _auth;

  // ================= CONNECT =================
  Future<void> connect([String? token]) async {
    if (_connecting) return;
    if (_connected && _auth) return;

    _connecting = true;

    try {
      _token = token ?? derivToken;

      final uri = Uri.parse(
        "wss://ws.derivws.com/websockets/v3?app_id=$derivAppId",
      );

      print("🔌 CONNECTING TO DERIV...");

      _channel = WebSocketChannel.connect(uri);

      _sub?.cancel();
      _sub = _channel!.stream.listen(
        (msg) {
          final data = jsonDecode(msg);

          if (data is Map<String, dynamic>) {
            _handle(data);
            _stream.add(data);
          }
        },
        onError: (e) {
          print("❌ SOCKET ERROR: $e");
          _connected = false;
          _auth = false;
          _reconnect();
        },
        onDone: () {
          print("⚠ SOCKET CLOSED");
          _connected = false;
          _auth = false;
          _reconnect();
        },
      );

      _connected = true;
      _auth = false;

      _send({"authorize": _token});
    } catch (e) {
      print("❌ CONNECT FAILED: $e");
      _connected = false;
      _auth = false;
    } finally {
      _connecting = false;
    }
  }

  // ================= HANDLE =================
  void _handle(Map<String, dynamic> data) {
    switch (data["msg_type"]) {
      case "authorize":
        _auth = true;
        print("✅ AUTH SUCCESS");
        break;

      case "balance":
        final b = data["balance"];
        if (b != null) {
          _balanceCache["main"] =
              double.tryParse(b["balance"].toString()) ?? 0;
        }
        break;

      case "candles":
        final echo = data["echo_req"] ?? {};
        final symbol = normalizeSymbol(echo["ticks_history"] ?? "");
        final tf = _mapTF(echo["granularity"] ?? 60);

        final raw = data["candles"] ?? [];

        final list = <model.Candle>[];

        for (final c in raw) {
          list.add(model.Candle(
            epoch: c["epoch"],
            open: (c["open"] ?? 0).toDouble(),
            high: (c["high"] ?? 0).toDouble(),
            low: (c["low"] ?? 0).toDouble(),
            close: (c["close"] ?? 0).toDouble(),
            volume: (c["volume"] ?? 0).toDouble(),
          ));
        }

        _data.putIfAbsent(symbol, () => {});
        _data[symbol]![tf] = list;
        break;

      case "proposal_open_contract":
      case "contract_update":
      case "tick":
        final id = data["contract_id"]?.toString();
        if (id != null && _contracts[id] != null) {
          _contracts[id]!.add(data);
        }
        break;
    }
  }

  // ================= SEND =================
  void _send(Map<String, dynamic> data) {
    if (!_connected || !_auth) return;
    _channel?.sink.add(jsonEncode(data));
  }

  // ================= SYMBOL =================
  String normalizeSymbol(String raw) {
    String s = raw.trim().toUpperCase();
    s = s.replaceAll(RegExp(r'[^A-Z0-9]'), '');

    while (s.startsWith('FRXFRX')) {
      s = s.substring(3);
    }

    if (!s.startsWith('FRX')) {
      s = 'FRX$s';
    }

    return s;
  }

  // ================= READY =================
  Future<void> ensureReady() async {
    if (!isConnected) {
      await connect();
    }

    int i = 0;
    while (!_auth && i < 20) {
      await Future.delayed(const Duration(milliseconds: 200));
      i++;
    }
  }

  // ================= BALANCE =================
  double get cachedBalance => _balanceCache["main"] ?? 0;

  Future<double> getBalance() async {
    await ensureReady();
    _send({"balance": 1});
    await Future.delayed(const Duration(seconds: 2));
    return cachedBalance;
  }

  // ================= CANDLES =================
  Future<void> subscribe(String symbolRaw) async {
    final symbol = normalizeSymbol(symbolRaw);

    await ensureReady();

    if (_subscribed.contains(symbol)) return;

    _subscribed.add(symbol);

    _send({
      "ticks_history": symbol,
      "style": "candles",
      "granularity": 60,
      "count": 500,
      "end": "latest",
      "adjust_start_time": 1
    });
  }
Future<List<model.Candle>> getCandlesWithTF(
  String symbolRaw, {
  TF timeframe = TF.m1,
}) async {
  await ensureReady();

  await subscribe(symbolRaw);

  // give websocket time to push candles
  await Future.delayed(const Duration(seconds: 2));

  return getCandles(symbolRaw, timeframe);
}
  List<model.Candle> getCandles(String symbolRaw, TF tf) {
    final symbol = normalizeSymbol(symbolRaw);
    return _data[symbol]?[tf] ?? [];
  }

  Future<double> getLastPrice(String symbolRaw) async {
    final symbol = normalizeSymbol(symbolRaw);

    await subscribe(symbol);

    final candles = getCandles(symbol, TF.m1);
    return candles.isNotEmpty ? candles.last.close : 0.0;
  }

  // ================= TRADE =================
  Future<String?> placeTrade(
    String pair,
    bool isBuy, {
    double stake = 10,
  }) async {
    await ensureReady();

    final symbol = normalizeSymbol(pair);

    final proposal = await _sendAndWait("proposal", {
      "proposal": 1,
      "amount": stake,
      "basis": "stake",
      "contract_type": isBuy ? "CALL" : "PUT",
      "currency": "USD",
      "symbol": symbol,
    });

    final p = proposal["proposal"];
    if (p == null) return null;

    final buy = await _sendAndWait("buy", {
      "buy": p["id"],
      "price": p["ask_price"] ?? stake,
    });

    return buy["buy"]?["contract_id"]?.toString();
  }

  // ================= CONTRACT STREAM =================
  StreamSubscription subscribeContract(
    String id,
    Function(Map<String, dynamic>) onUpdate,
  ) {
    final ctrl = _contracts.putIfAbsent(
      id,
      () => StreamController<Map<String, dynamic>>.broadcast(),
    );

    _send({
      "proposal_open_contract": 1,
      "contract_id": id,
      "subscribe": 1
    });

    return ctrl.stream.listen(onUpdate);
  }

  Future<void> closeTradeById(String id) async {
    _send({
      "proposal_open_contract": 1,
      "contract_id": id,
      "cancel": 1
    });

    await _contracts[id]?.close();
    _contracts.remove(id);
  }

  // ================= WAIT =================
  Future<Map<String, dynamic>> _sendAndWait(
    String type,
    Map<String, dynamic> data,
  ) async {
    final c = Completer<Map<String, dynamic>>();

    late StreamSubscription sub;

    sub = stream.listen((event) {
      if (!c.isCompleted && event["msg_type"] == type) {
        c.complete(event);
        sub.cancel();
      }
    });

    _send(data);
    return c.future;
  }

  // ================= RECONNECT =================
  Future<void> _reconnect() async {
    if (_reconnecting) return;

    _reconnecting = true;

    _connected = false;
    _auth = false;

    print("🔄 Reconnecting in 5s...");

    await Future.delayed(const Duration(seconds: 5));

    _reconnecting = false;

    await connect(_token);
  }

  // ================= MARKET =================
  Future<List<String>> getMarketPairs() async {
    if (_marketPairs.isEmpty) {
      _send({"active_symbols": "brief"});
      await Future.delayed(const Duration(seconds: 2));
    }
    return _marketPairs;
  }

  TF _mapTF(int g) {
    switch (g) {
      case 3600:
        return TF.h1;
      case 14400:
        return TF.h4;
      case 86400:
        return TF.d1;
      case 604800:
        return TF.w1;
      default:
        return TF.m1;
    }
  }

  void dispose() {
    _sub?.cancel();
    _channel?.sink.close();
    _stream.close();
  }
}