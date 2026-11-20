/// 行情数据层：A 股 / 港股 / 美股指数 / 伦敦金银。
///
/// 口径与接口选择依据 `docs/data-sources.md`（本机实测，不是照搬旧笔记）：
///  - K 线走腾讯 `fqkline`（日/周/月）和 `mkline`（分钟），UTF-8，稳定
///  - 分钟线必须用 `ifzq.gtimg.cn`，`web.ifzq` 会 302 到 `web3` 然后超时
///  - 实时快照是 **GBK**，必须 `gbk_bytes.decode`
///  - 东财 `push2` 会超时，实时改用 `push2delay`；K 线用 `push2his`
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:gbk_codec/gbk_codec.dart';

import 'chanlun.dart';

/// 取数失败。消息面向用户，不要暴露堆栈。
class StockDataError implements Exception {
  StockDataError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一个周期的 K 线集合。
class KlineSeries {
  KlineSeries({required this.symbol, required this.name, required this.period, required this.bars});

  final String symbol;
  final String name;

  /// `day` / `week` / `month` / `m60` / `m30` / `m15` / `m5`
  final String period;
  final List<Bar> bars;

  int get length => bars.length;
  Bar get last => bars.last;
  Bar get first => bars.first;

  /// 最新收盘价。
  double get close => bars.isEmpty ? 0 : bars.last.c;
}

/// 实时快照。
class Quote {
  Quote({
    required this.symbol,
    required this.name,
    required this.price,
    required this.prevClose,
    required this.open,
    required this.high,
    required this.low,
    required this.volume,
    this.amount,
    this.time,
  });

  final String symbol;
  final String name;
  final double price;
  final double prevClose;
  final double open;
  final double high;
  final double low;
  final double volume;
  final double? amount;
  final String? time;

  double get change => price - prevClose;
  double get changePct => prevClose == 0 ? 0 : (price - prevClose) / prevClose * 100;
}

const _ua = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

/// 缠论取数建议根数：实测 400 根起结果收敛，腾讯日线最多约 640 根。
const int chanBarCount = 640;

/// A 股 / 指数 / 境外品种的行情访问。
class StockSource {
  StockSource({HttpClient? client})
    : _client = client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 10));

  final HttpClient _client;

  Future<void> close() {
    _client.close(force: true);
    return Future.value();
  }

  // ---------------------------------------------------------------- HTTP

  Future<Uint8List> _bytes(String url, {String? referer}) async {
    try {
      final req = await _client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, _ua);
      req.headers.set(HttpHeaders.acceptHeader, '*/*');
      if (referer != null) req.headers.set(HttpHeaders.refererHeader, referer);
      final resp = await req.close().timeout(const Duration(seconds: 12));
      final builder = await resp.fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d));
      if (resp.statusCode != 200) {
        throw StockDataError('接口返回 HTTP ${resp.statusCode}');
      }
      return builder.takeBytes();
    } on StockDataError {
      rethrow;
    } catch (e) {
      throw StockDataError('网络请求失败：$e');
    }
  }

  Future<String> _text(String url, {String? referer}) async {
    final b = await _bytes(url, referer: referer);
    return utf8.decode(b, allowMalformed: true);
  }

  /// 腾讯 / 新浪的实时接口返回 GBK。注意用 `gbk_bytes.decode`，
  /// `gbk.decode` 实测会输出乱码。
  Future<String> _gbkText(String url, {String? referer}) async {
    final b = await _bytes(url, referer: referer);
    return gbk_bytes.decode(b);
  }

  // ------------------------------------------------------------ 代码规范化

  /// 把用户输入（`300274` / `sz300274` / `阳光电源`）规范成腾讯用的 `sz300274`。
  ///
  /// 纯数字按 A 股规则补前缀：6/9 开头沪市，0/2/3 开头深市，4/8 开头北交所。
  String normalize(String input) {
    final s = input.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (s.isEmpty) throw StockDataError('股票代码不能为空');

    // 已经是 sz300274 / sh600519 形式
    final m = RegExp(r'^(sh|sz|bj)(\d{6})$').firstMatch(s);
    if (m != null) return s;

    // 境外品种原样透传：腾讯用 usIXIC / usAAPL / hk00700 这类代码
    final us = RegExp(r'^(us|hk)([a-z]+\.?[a-z]*|\d{4,5})$').firstMatch(s);
    if (us != null) return s;

    // 纯 6 位数字
    if (RegExp(r'^\d{6}$').hasMatch(s)) {
      final c = s[0];
      if (c == '6' || c == '9') return 'sh$s';
      if (c == '4' || c == '8') return 'bj$s';
      return 'sz$s';
    }

    throw StockDataError('无法识别的代码「$input」，请用 6 位数字或 sh/sz 前缀');
  }

  // ------------------------------------------------------------- K 线

  static const _periodMap = <String, String>{
    'day': 'day',
    'd': 'day',
    '日': 'day',
    '日线': 'day',
    'week': 'week',
    'w': 'week',
    '周': 'week',
    '周线': 'week',
    'month': 'month',
    'm': 'month',
    '月': 'month',
    '月线': 'month',
    'm60': 'm60',
    '60': 'm60',
    '60min': 'm60',
    'm30': 'm30',
    '30': 'm30',
    '30min': 'm30',
    'm15': 'm15',
    '15': 'm15',
    '15min': 'm15',
    'm5': 'm5',
    '5': 'm5',
    '5min': 'm5',
  };

  /// 把用户写法映射成标准周期名。
  static String normalizePeriod(String p) {
    final key = p.trim().toLowerCase();
    final v = _periodMap[key];
    if (v == null) {
      throw StockDataError('不支持的周期「$p」，可用：日线/周线/月线/60/30/15/5 分钟');
    }
    return v;
  }

  /// 拉 K 线。
  ///
  /// [count] 默认 640（缠论建议值）。分钟线腾讯单次上限较低，会自动取实际返回。
  Future<KlineSeries> kline(String symbol, {String period = 'day', int count = chanBarCount}) async {
    final code = normalize(symbol);
    final p = normalizePeriod(period);
    final isMinute = p.startsWith('m');

    final String url;
    if (isMinute) {
      // 分钟线：必须 ifzq.gtimg.cn（web.ifzq 会 302 到 web3 超时）
      url = 'https://ifzq.gtimg.cn/appstock/app/kline/mkline?param=$code,$p,,$count';
    } else {
      url = 'https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=$code,$p,,,$count,qfq';
    }

    final body = await _text(url);
    final root = jsonDecode(body);
    if (root is! Map || root['code'] != 0) {
      throw StockDataError('接口返回异常：${body.length > 120 ? body.substring(0, 120) : body}');
    }

    final data = root['data'];
    if (data is! Map) throw StockDataError('返回里没有 data 字段');
    final node = data[code];
    if (node is! Map) throw StockDataError('没有找到 $code 的行情数据');

    // 字段名可能是 qfqday / day / qfqweek / week / m60 ...
    List<dynamic>? rows;
    for (final key in ['qfq$p', p, 'qfq${p}day', '${p}day']) {
      final v = node[key];
      if (v is List && v.isNotEmpty) {
        rows = v;
        break;
      }
    }
    if (rows == null) {
      // 分钟线可能在别的键下，兜底扫描
      for (final e in node.entries) {
        final v = e.value;
        if (v is List && v.isNotEmpty && v.first is List && (v.first as List).length >= 5) {
          rows = v;
          break;
        }
      }
    }
    if (rows == null || rows.isEmpty) {
      throw StockDataError('$code 没有 $p 的 K 线数据');
    }

    final bars = <Bar>[];
    for (final r in rows) {
      if (r is! List || r.length < 5) continue;
      final t = r[0].toString();
      final o = _d(r[1]);
      final c = _d(r[2]);
      final h = _d(r[3]);
      final l = _d(r[4]);
      final v = r.length > 5 ? _d(r[5]) : 0.0;
      if (o == null || c == null || h == null || l == null) continue;
      bars.add(Bar(o, h, l, c, v: v ?? 0, t: t));
    }
    if (bars.isEmpty) throw StockDataError('$code 的 K 线解析后为空');

    final name = _nameFromNode(node.cast<String, dynamic>()) ?? code;

    return KlineSeries(symbol: code, name: name, period: p, bars: bars);
  }

  String? _nameFromNode(Map<String, dynamic> node) {
    final qt = node['qt'];
    if (qt is Map) {
      for (final v in qt.values) {
        if (v is List && v.length > 1) return v[1]?.toString();
      }
    }
    return null;
  }

  static double? _d(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  // ------------------------------------------------------------ 实时快照

  /// 实时快照。腾讯 GBK 接口优先，失败回退东财延迟行情。
  Future<Quote> quote(String symbol) async {
    final code = normalize(symbol);
    try {
      return await _quoteTencent(code);
    } on StockDataError {
      return await _quoteEastmoney(code);
    }
  }

  Future<Quote> _quoteTencent(String code) async {
    final body = await _gbkText('https://qt.gtimg.cn/q=$code');
    final m = RegExp(r'="([^"]*)"').firstMatch(body);
    if (m == null) throw StockDataError('腾讯快照格式异常');
    final f = m.group(1)!.split('~');
    if (f.length < 40) throw StockDataError('腾讯快照字段不足');

    return Quote(
      symbol: code,
      name: f[1],
      price: _d(f[3]) ?? 0,
      prevClose: _d(f[4]) ?? 0,
      open: _d(f[5]) ?? 0,
      high: _d(f[33]) ?? 0,
      low: _d(f[34]) ?? 0,
      volume: (_d(f[6]) ?? 0) * 100, // 手 -> 股
      amount: (_d(f[37]) ?? 0) * 10000, // 万元 -> 元
      time: f[30],
    );
  }

  Future<Quote> _quoteEastmoney(String code) async {
    // 东财 secid：沪市前缀 1，深市/北交所前缀 0
    final market = code.startsWith('sh') ? '1' : '0';
    final num = code.substring(2);
    final body = await _text(
      'https://push2delay.eastmoney.com/api/qt/stock/get'
      '?secid=$market.$num&fields=f43,f44,f45,f46,f47,f48,f57,f58,f60,f169,f170',
    );
    final root = jsonDecode(body);
    final data = root is Map ? root['data'] : null;
    if (data is! Map) throw StockDataError('东财快照没有数据');

    double px(Object? v) {
      final d = _d(v) ?? 0;
      return d / 100; // 东财价格字段是分
    }

    return Quote(
      symbol: code,
      name: data['f58']?.toString() ?? code,
      price: px(data['f43']),
      prevClose: px(data['f60']),
      open: px(data['f46']),
      high: px(data['f44']),
      low: px(data['f45']),
      volume: _d(data['f47']) ?? 0,
      amount: _d(data['f48']),
    );
  }

  // ------------------------------------------------------------ 多级别

  /// 并发拉多个级别，返回按固定顺序排列的结果（失败的有 error）。
  Future<List<KlineSeries>> multiLevel(
    String symbol, {
    List<String> periods = const ['week', 'day', 'm60', 'm30', 'm15'],
    int count = chanBarCount,
  }) async {
    final results = await Future.wait(
      periods.map((p) async {
        try {
          return await kline(symbol, period: p, count: count);
        } catch (_) {
          return null;
        }
      }),
    );
    return [for (final r in results) ?r];
  }
}
