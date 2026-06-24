import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/candle.dart' as model;

const String derivToken = "YOUR_TOKEN_HERE";
const int derivAppId = 1089;

enum TF { m1, h1, h4, d1, w1 }

class DerivService {
  static final DerivService instance = DerivService._internal();
  DerivService._internal();

  factory DerivService() => instance;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  bool _connected = false;
  bool _auth = false;
  bool _connecting = false;

  String? _token;

  final StreamController<Map<String, dynamic>> _stream =
      StreamController.broadcast();

  Stream<Map<String, dynamic>> get stream => _stream.stream;

  final Map<String, Map<TF, List<model.Candle>>> _data = {};
  final Set<String> _subscribed = {};
  final Map<String, StreamController<Map<String, dynamic>>> _contracts = {};
  final Map<String, double> _balanceCache = {};

  bool get isConnected => _connected && _auth;

  // ================= CONNECT =================
  Future<void> connect([String? token]) async {
    if (_connected || _connecting) return;

    _connecting = true;
    _token = token ?? derivToken;

    final uri =
        Uri.parse("wss://ws.derivws.com/websockets/v3?app_id=$derivAppId");

    _channel = WebSocketChannel.connect(uri);

    _sub = _channel!.stream.listen((msg) {
      final data = jsonDecode(msg);

      if (data is Map<String, dynamic>) {
        _handle(data);
        _stream.add(data);
      }
    }, onError: (_) => _reconnect(), onDone: _reconnect);

    _connected = true;
    _auth = false;

    _send({"authorize": _token});

    _connecting = false;
  }

  // ================= HANDLE =================
  void _handle(Map<String, dynamic> data) {
    switch (data["msg_type"]) {
      case "authorize":
        _auth = true;
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

        final list = raw.map<model.Candle>((c) {
          return model.Candle(
            epoch: c["epoch"],
            open: (c["open"] ?? 0).toDouble(),
            high: (c["high"] ?? 0).toDouble(),
            low: (c["low"] ?? 0).toDouble(),
            close: (c["close"] ?? 0).toDouble(),
            volume: (c["volume"] ?? 0).toDouble(),
          );
        }).toList();

        _data.putIfAbsent(symbol, () => {});
        _data[symbol]![tf] = list;
        break;
    }
  }

  // ================= SEND =================
  void _send(Map<String, dynamic> data) {
    _channel?.sink.add(jsonEncode(data));
  }

  Future<void> ensureReady() async {
    if (isConnected) return;
    await connect();
  }

  // ================= SUBSCRIBE =================
  Future<void> subscribeCandles(String symbolRaw, {TF tf = TF.h1}) async {
    final symbol = normalizeSymbol(symbolRaw);
    final key = "$symbol-${tf.name}";

    if (_subscribed.contains(key)) return;
    _subscribed.add(key);

    _send({
      "ticks_history": symbol,
      "style": "candles",
      "granularity": _tfToSec(tf),
      "count": 1000000,
      "end": "latest"
    });
  }

  Future<void> subscribe(String symbol) async {
    await subscribeCandles(symbol, tf: TF.h1);
    await subscribeCandles(symbol, tf: TF.h4);
    await subscribeCandles(symbol, tf: TF.d1);
    await subscribeCandles(symbol, tf: TF.w1);
  }

  // ================= GET CANDLES =================
  List<model.Candle> getCandles(String symbolRaw, TF tf) {
    final symbol = normalizeSymbol(symbolRaw);
    return _data[symbol]?[tf] ?? [];
  }

  // ================= FETCH =================
  Future<List<model.Candle>> fetchCandles(
    String symbolRaw,
    TF tf,
  ) async {
    final symbol = normalizeSymbol(symbolRaw);

    final c = Completer<List<model.Candle>>();

    late StreamSubscription sub;

    sub = stream.listen((data) {
      if (data["msg_type"] == "candles") {
        final echo = data["echo_req"] ?? {};
        final sym = normalizeSymbol(echo["ticks_history"] ?? "");

        if (sym != symbol) return;

        final raw = data["candles"] ?? [];

        final list = raw.map<model.Candle>((c) {
          return model.Candle(
            epoch: c["epoch"],
            open: (c["open"] ?? 0).toDouble(),
            high: (c["high"] ?? 0).toDouble(),
            low: (c["low"] ?? 0).toDouble(),
            close: (c["close"] ?? 0).toDouble(),
            volume: (c["volume"] ?? 0).toDouble(),
          );
        }).toList();

        c.complete(list);
        sub.cancel();
      }
    });

    _send({
      "ticks_history": symbol,
      "style": "candles",
      "granularity": _tfToSec(tf),
      "count": 1000000
    });

    return c.future;
  }

  // ================= MARKET PAIRS (FIXED) =================
  Future<List<String>> getMarketPairs() async {
    _send({"active_symbols": "brief"});

    final c = Completer<List<String>>();

    late StreamSubscription sub;

    sub = stream.listen((e) {
      if (e["msg_type"] == "active_symbols") {
        final list = e["active_symbols"] as List? ?? [];
        c.complete(list.map((x) => x["symbol"].toString()).toList());
        sub.cancel();
      }
    });

    return c.future;
  }

  // ================= TRADE (FIXED) =================
  Future<String?> placeTrade(
    String pair,
    bool isBuy, {
    double stake = 10,
  }) async {
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

  // ================= LAST PRICE (FIXED) =================
  Future<double> getLastPrice(String symbol) async {
    final candles = await fetchCandles(symbol, TF.m1);
    return candles.isNotEmpty ? candles.last.close : 0;
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

    return ctrl.stream.listen(onUpdate);
  }

  Future<void> closeTradeById(String id) async {
    await _contracts[id]?.close();
    _contracts.remove(id);
  }

  // ================= HELPERS =================
  Future<Map<String, dynamic>> _sendAndWait(
    String type,
    Map<String, dynamic> data,
  ) async {
    final c = Completer<Map<String, dynamic>>();

    late StreamSubscription sub;

    sub = stream.listen((e) {
      if (!c.isCompleted && e["msg_type"] == type) {
        c.complete(e);
        sub.cancel();
      }
    });

    _send(data);
    return c.future;
  }

  Future<void> _reconnect() async {
    _connected = false;
    _auth = false;
    await Future.delayed(const Duration(seconds: 3));
    await connect(_token);
  }
// ================= BALANCE =================
Future<double> getBalance() async {
  _send({"balance": 1});

  final c = Completer<double>();

  late StreamSubscription sub;

  sub = stream.listen((e) {
    if (e["msg_type"] == "balance") {
      final b = e["balance"];
      final value =
          double.tryParse(b?["balance"]?.toString() ?? "0") ?? 0;

      c.complete(value);
      sub.cancel();
    }
  });

  return c.future;
}

// ================= CANDLES WITH TF =================
Future<List<model.Candle>> getCandlesWithTF(
  String symbolRaw, {
  TF timeframe = TF.h1,
}) async {
  await subscribeCandles(symbolRaw, tf: timeframe);

  await Future.delayed(const Duration(seconds: 2));

  return getCandles(symbolRaw, timeframe);
}
  // ================= TF =================
  int _tfToSec(TF tf) {
    switch (tf) {
      case TF.m1:
        return 60;
      case TF.h1:
        return 3600;
      case TF.h4:
        return 14400;
      case TF.d1:
        return 86400;
      case TF.w1:
        return 604800;
    }
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

  String normalizeSymbol(String raw) {
    return raw.trim().toUpperCase();
  }
}