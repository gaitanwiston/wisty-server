import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/candle.dart' as model;

const String derivToken =
    "pat_0fccfffc5d1eaace805fb961cd606399a8665f15e6e40da9cdd313a67ac8ec08";

const int derivAppId = 1089;

enum TF { m1, h1, h4, d1, w1, mn }

class DerivService {
  static final DerivService instance = DerivService._internal();
  DerivService._internal();

  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  bool _connected = false;
  bool _auth = false;

  final StreamController<Map<String, dynamic>> _stream =
      StreamController.broadcast();

  Stream<Map<String, dynamic>> get stream => _stream.stream;

  final Map<String, Map<TF, List<model.Candle>>> _data = {};
  final Set<String> _subscribed = {};

  Timer? _keepAlive;

  bool get isConnected => _connected && _auth;

  // ================= CONNECT =================
  Future<void> connect([String? token]) async {
    if (_connected) return;

    final uri =
        Uri.parse("wss://ws.derivws.com/websockets/v3?app_id=$derivAppId");

    _channel = WebSocketChannel.connect(uri);
    _connected = true;

    _sub?.cancel();

    _sub = _channel!.stream.listen(
      (msg) {
        try {
          final data = jsonDecode(msg);

          if (data is Map<String, dynamic>) {
            _handle(data);
            _stream.add(data);
          }
        } catch (_) {}
      },
      onDone: _reconnect,
      onError: (_) => _reconnect(),
      cancelOnError: true,
    );

    _send({"authorize": token ?? derivToken});
    _send({"active_symbols": "brief"});

    _startKeepAlive();
  }

  // ================= KEEP ALIVE =================
  void _startKeepAlive() {
    _keepAlive?.cancel();
    _keepAlive = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_connected) _send({"ping": 1});
    });
  }

  // ================= ENSURE READY =================
  Future<void> ensureReady() async {
    if (isConnected) return;
    await connect();
  }

  // ================= HANDLE =================
  void _handle(Map<String, dynamic> data) {
    final type = data["msg_type"];

    if (type == "authorize") {
      _auth = true;
    }

    final candles = data["candles"];
    if (candles is! List) return;

    final echo = data["echo_req"] ?? {};
    final symbol = normalizeSymbol(echo["ticks_history"] ?? "");
    if (symbol.isEmpty) return;

    final gran = echo["granularity"] ?? 60;
    final tf = _mapTF(gran);

    final parsed = candles
        .where((c) => c is Map)
        .map<model.Candle>((c) {
      return model.Candle(
        epoch: c["epoch"] ?? 0,
        open: (c["open"] ?? 0).toDouble(),
        high: (c["high"] ?? 0).toDouble(),
        low: (c["low"] ?? 0).toDouble(),
        close: (c["close"] ?? 0).toDouble(),
        volume: (c["volume"] ?? 0).toDouble(),
      );
    }).toList();

    _data.putIfAbsent(symbol, () => {});
    _data[symbol]![tf] = parsed;
  }

  // ================= SUBSCRIBE =================
  Future<void> subscribe(String symbolRaw) async {
    await ensureReady();

    final symbol = normalizeSymbol(symbolRaw);

    if (_subscribed.contains(symbol)) return;
    _subscribed.add(symbol);

    await subscribeCandles(symbol, tf: TF.h1);
    await subscribeCandles(symbol, tf: TF.h4);
    await subscribeCandles(symbol, tf: TF.d1);
    await subscribeCandles(symbol, tf: TF.w1);
  }

  Future<void> subscribeCandles(String symbolRaw, {TF tf = TF.h1}) async {
    final symbol = normalizeSymbol(symbolRaw);

    _send({
      "ticks_history": symbol,
      "style": "candles",
      "granularity": _tfToSec(tf),
      "count": 500,
      "end": "latest",
      "subscribe": 1
    });
  }

  // ================= GET CANDLES =================
  List<model.Candle> getCandles(String symbolRaw, TF tf) {
    final symbol = normalizeSymbol(symbolRaw);
    return _data[symbol]?[tf] ?? [];
  }

  Future<List<model.Candle>> getCandlesWithTF(
    String symbolRaw, {
    TF timeframe = TF.h1,
  }) async {
    await ensureReady();
    await subscribeCandles(symbolRaw, tf: timeframe);

    await Future.delayed(const Duration(milliseconds: 600));

    return getCandles(symbolRaw, timeframe);
  }

  // ================= MARKET PAIRS (FIXED) =================
  Future<List<String>> getMarketPairs() async {
    await ensureReady();

    final c = Completer<List<String>>();

    late StreamSubscription sub;
    sub = stream.listen((e) {
      if (e["msg_type"] == "active_symbols") {
        final list = e["active_symbols"];

        if (list is! List) {
          c.complete([]);
          sub.cancel();
          return;
        }

        c.complete(
          list
              .whereType<Map>()
              .map((x) => x["symbol"].toString())
              .toList(),
        );

        sub.cancel();
      }
    });

    _send({"active_symbols": "brief"});

    return c.future;
  }

  // ================= BALANCE (FIXED) =================
  Future<double> getBalance() async {
    await ensureReady();

    final c = Completer<double>();

    late StreamSubscription sub;
    sub = stream.listen((e) {
      if (e["msg_type"] == "balance") {
        final b = e["balance"];

        if (b is! Map) {
          c.complete(0);
          sub.cancel();
          return;
        }

        c.complete(double.tryParse(b["balance"].toString()) ?? 0);

        sub.cancel();
      }
    });

    _send({"balance": 1});

    return c.future;
  }

  // ================= LAST PRICE =================
  Future<double> getLastPrice(String symbol) async {
    final candles = await getCandlesWithTF(symbol, timeframe: TF.m1);
    return candles.isEmpty ? 0 : candles.last.close;
  }

  // ================= TRADE =================
  Future<String?> placeTrade(
    String symbol,
    bool isBuy, {
    double stake = 10,
  }) async {
    await ensureReady();

    final proposal = await _sendAndWait("proposal", {
      "proposal": 1,
      "amount": stake,
      "basis": "stake",
      "contract_type": isBuy ? "CALL" : "PUT",
      "currency": "USD",
      "symbol": normalizeSymbol(symbol),
    });

    final p = proposal["proposal"];
    if (p is! Map) return null;

    final buy = await _sendAndWait("buy", {
      "buy": p["id"],
      "price": p["ask_price"] ?? stake,
    });

    return buy["buy"]?["contract_id"]?.toString();
  }

  // ================= SAFE REQUEST =================
  Future<Map<String, dynamic>> _sendAndWait(
    String type,
    Map<String, dynamic> data,
  ) async {
    final c = Completer<Map<String, dynamic>>();

    late StreamSubscription sub;
    sub = stream.listen((e) {
      if (e["msg_type"] == type) {
        c.complete(e);
        sub.cancel();
      }
    });

    _send(data);

    return c.future;
  }

  // ================= CONTRACT =================
  StreamSubscription subscribeContract(
    String id,
    Function(Map<String, dynamic>) onUpdate,
  ) {
    return stream.listen((e) {
      if (e["contract_id"]?.toString() == id) {
        onUpdate(e);
      }
    });
  }

  Future<void> closeTradeById(String id) async {
    _send({"forget": id});
  }

  // ================= HELPERS =================
  void _send(Map<String, dynamic> d) {
    try {
      _channel?.sink.add(jsonEncode(d));
    } catch (_) {}
  }

  Future<void> _reconnect() async {
    _connected = false;
    _auth = false;

    await Future.delayed(const Duration(seconds: 2));
    await connect();
  }

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
      case TF.mn:
        return 2592000;
    }
  }

  TF _mapTF(int g) {
    switch (g) {
      case 60:
        return TF.m1;
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
    return raw.toUpperCase().replaceAll("FRX", "").trim();
  }
}