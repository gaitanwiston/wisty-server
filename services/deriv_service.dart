import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/candle.dart' as model;

const String derivToken =
    "pat_0fccfffc5d1eaace805fb961cd606399a8665f15e6e40da9cdd313a67ac8ec08";

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

  Timer? _keepAlive;

  // ================= CONNECT =================
  Future<void> connect([String? token]) async {
    if (_connected || _connecting) return;

    _connecting = true;
    _token = token ?? derivToken;

    final uri = Uri.parse(
        "wss://ws.derivws.com/websockets/v3?app_id=$derivAppId");

    _channel = WebSocketChannel.connect(uri);

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
      onError: (_) => _reconnect(),
      onDone: _reconnect,
      cancelOnError: true,
    );

    _connected = true;
    _auth = false;

    _send({"authorize": _token});

    _startKeepAlive();

    _connecting = false;
  }

  // ================= KEEP ALIVE =================
  void _startKeepAlive() {
    _keepAlive?.cancel();
    _keepAlive = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_connected) _send({"ping": 1});
    });
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

        final list = (raw as List).map<model.Candle>((c) {
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

        // 🔥 FIX: ensure higher TF build (from Deriv1 logic)
        _buildFallback(symbol);

        break;
    }
  }

  // ================= SEND =================
  void _send(Map<String, dynamic> data) {
    try {
      _channel?.sink.add(jsonEncode(data));
    } catch (_) {}
  }

  Future<void> ensureReady() async {
    if (isConnected) return;
    await connect();
  }

  // ================= SUBSCRIBE =================
  Future<void> subscribeCandles(
    String symbolRaw, {
    TF tf = TF.h1,
  }) async {
    await ensureReady();

    final symbol = normalizeSymbol(symbolRaw);
    final key = "$symbol-${tf.name}";

    if (_subscribed.contains(key)) return;

    _subscribed.add(key);

    _send({
      "ticks_history": symbol,
      "style": "candles",
      "granularity": _tfToSec(tf),
      "count": tf == TF.w1 ? 520 : 5000,
      "end": "latest",
      "subscribe": 1
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

    final list = _data[symbol]?[tf] ?? [];

    if (tf == TF.w1 && list.isEmpty) {
      final d1 = _data[symbol]?[TF.d1] ?? [];
      return _buildWeeklyFromDaily(d1);
    }

    return list;
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
      if (data["msg_type"] != "candles") return;

      final echo = data["echo_req"] ?? {};
      final sym = normalizeSymbol(echo["ticks_history"] ?? "");

      if (sym != symbol) return;

      final raw = data["candles"] ?? [];

      final list = (raw as List).map<model.Candle>((c) {
        return model.Candle(
          epoch: c["epoch"],
          open: (c["open"] ?? 0).toDouble(),
          high: (c["high"] ?? 0).toDouble(),
          low: (c["low"] ?? 0).toDouble(),
          close: (c["close"] ?? 0).toDouble(),
          volume: (c["volume"] ?? 0).toDouble(),
        );
      }).toList();

      if (!c.isCompleted) c.complete(list);
      sub.cancel();
    });

    _send({
      "ticks_history": symbol,
      "style": "candles",
      "granularity": _tfToSec(tf),
      "count": tf == TF.w1 ? 520 : 5000,
      "end": "latest"
    });

    return c.future;
  }

  // ================= MARKET PAIRS =================
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

  // ================= TRADE =================
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

  // ================= LAST PRICE =================
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

  // ================= RECONNECT =================
  Future<void> _reconnect() async {
    _connected = false;
    _auth = false;

    await Future.delayed(const Duration(seconds: 3));
    await connect(_token);

    final old = List<String>.from(_subscribed);
    _subscribed.clear();

    for (final key in old) {
      final parts = key.split("-");
      final symbol = parts[0];

      final tf = TF.values.firstWhere(
        (e) => e.name == parts[1],
        orElse: () => TF.h1,
      );

      await subscribeCandles(symbol, tf: tf);
    }
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

  String normalizeSymbol(String raw) =>
      raw.trim().toUpperCase().replaceAll("FRX", "");

Future<List<model.Candle>> getCandlesWithTF(
  String symbolRaw, {
  TF timeframe = TF.h1,
}) async {
  await ensureReady();

  final symbol = normalizeSymbol(symbolRaw);

  await subscribeCandles(symbol, tf: timeframe);

  int retries = 0;

  while ((_data[symbol]?[timeframe] ?? []).isEmpty && retries < 10) {
    await Future.delayed(const Duration(milliseconds: 500));
    retries++;
  }

  return _data[symbol]?[timeframe] ?? [];
}

  // ================= FIXED FALLBACK SYSTEM =================
  void _buildFallback(String symbol) {
    final m1 = _data[symbol]?[TF.m1] ?? [];
    final h4 = _data[symbol]?[TF.h4] ?? [];
    final d1 = _data[symbol]?[TF.d1] ?? [];

    if (m1.length >= 10) {
      _data[symbol]![TF.h1] = _aggregate(m1, 60);
      _data[symbol]![TF.h4] = _aggregate(m1, 240);
      _data[symbol]![TF.d1] = _aggregate(m1, 1440);
      _data[symbol]![TF.w1] = _aggregate(m1, 10080);
    }

    if (m1.length < 10 && h4.isNotEmpty) {
      _data[symbol]![TF.h1] = h4;
      _data[symbol]![TF.h4] = h4;
      _data[symbol]![TF.d1] = d1;
    }
  }

  List<model.Candle> _aggregate(List<model.Candle> base, int sec) {
    final out = <model.Candle>[];

    for (final c in base) {
      final bucket = (c.epoch ~/ sec) * sec;

      if (out.isEmpty || out.last.epoch != bucket) {
        out.add(c);
      } else {
        final last = out.last;

        out[out.length - 1] = model.Candle(
          epoch: last.epoch,
          open: last.open,
          close: c.close,
          high: max(last.high, c.high),
          low: min(last.low, c.low),
          volume: last.volume + c.volume,
        );
      }
    }

    return out;
  }

  List<model.Candle> _buildWeeklyFromDaily(List<model.Candle> d1) {
    final result = <model.Candle>[];

    for (int i = 0; i + 4 < d1.length; i += 5) {
      final chunk = d1.sublist(i, i + 5);

      result.add(model.Candle(
        epoch: chunk.first.epoch,
        open: chunk.first.open,
        high: chunk.map((e) => e.high).reduce(max),
        low: chunk.map((e) => e.low).reduce(min),
        close: chunk.last.close,
        volume: chunk.fold<double>(
          0.0,
          (a, b) => a + (b.volume ?? 0.0),
        ),
      ));
    }

    return result;
  }
}