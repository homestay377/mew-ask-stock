/// 行情数据层：A 股 / 港股 / 美股指数 / 伦敦金银。
///
/// 口径与接口选择依据 `docs/data-sources.md`（本机实测，不是照搬旧笔记）：
///  - K 线走腾讯 `fqkline`（日/周/月）和 `mkline`（分钟），UTF-8，稳定
///  - 分钟线必须用 `ifzq.gtimg.cn`，`web.ifzq` 会 302 到 `web3` 然后超时
///  - 实时快照是 **GBK**，必须 `gbk_bytes.decode`
///  - 东财 `push2` 会超时，实时改用 `push2delay`；K 线用 `push2his`
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:gbk_codec/gbk_codec.dart';

import 'chanlun.dart';
import 'data_quality.dart';
import 'minute.dart';
import 'numbers.dart';
import 'stock_fundamental.dart';
import 'stock_search.dart';

/// 取数失败。消息面向用户，不要暴露堆栈。
class StockDataError implements Exception {
  StockDataError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一个周期的 K 线集合。
class KlineSeries {
  KlineSeries({
    required this.symbol,
    required this.name,
    required this.period,
    required this.bars,
    this.source = 'tencent',
    this.fallbackReason,
    DateTime? fetchedAt,
    this.fromCache = false,
    this.cacheAge,
  }) : fetchedAt = fetchedAt ?? DateTime.now();

  final String symbol;
  final String name;

  /// `day` / `week` / `month` / `m60` / `m30` / `m15` / `m5`
  final String period;
  final List<Bar> bars;

  /// 数据来源：`tencent`（前复权）、`sina`（不复权，备源）、`eastmoney`（前复权）。
  /// 备源时除权日附近会有跳空，缠论可能因此多出假信号，值得在摘要里提一句。
  final String source;

  /// 走备源时的降级原因（主源报了什么错）。主源成功时为 null。
  /// 这不是给人看的报错弹窗，是给分析层判断「要不要打折」的依据。
  final String? fallbackReason;

  /// 这批数据**真正从网络拉到的时刻**。缓存命中时不会被改写成读缓存的时刻，
  /// 否则「数据有多旧」就永远看不出来了。
  final DateTime fetchedAt;

  /// true = 来自内存/磁盘缓存，不是刚刚拉的。
  final bool fromCache;

  /// 缓存命中时的数据年龄；直接从网络拿的是 null。
  final Duration? cacheAge;

  bool get isFallback => source != 'tencent';

  /// 复权口径。**不同口径的序列不能直接拼接**——不复权的序列在除权日会有跳空。
  String get adjust => switch (source) {
    'sina' => '不复权',
    _ => '前复权',
  };

  /// 数据质量体检，惰性算一次（O(n)，640 根也就几十微秒）。
  KlineQuality get quality => _quality ??= assessBars(bars, period);
  KlineQuality? _quality;

  /// 最后一根 K 线的时间状态（收没收盘、多旧）。
  BarClock get clock => barClock(period, bars.isEmpty ? '' : bars.last.t);

  /// 缓存命中时用它打标，fetchedAt 原样保留。
  KlineSeries asCached(Duration age) => KlineSeries(
    symbol: symbol,
    name: name,
    period: period,
    bars: bars,
    source: source,
    fallbackReason: fallbackReason,
    fetchedAt: fetchedAt,
    fromCache: true,
    cacheAge: age,
  ).._quality = _quality;

  /// 给降级结果补上原因，其它原样。
  KlineSeries withFallback(String? reason) => KlineSeries(
    symbol: symbol,
    name: name,
    period: period,
    bars: bars,
    source: source,
    fallbackReason: reason,
    fetchedAt: fetchedAt,
    fromCache: fromCache,
    cacheAge: cacheAge,
  ).._quality = _quality;

  /// 一句话描述数据来历，摘要里直接用。
  /// 例：`腾讯 · 前复权 · 最后一根 2026-11-20 已收盘 · 拉取于 2 分钟前`
  String get provenance {
    final parts = <String>['$source · $adjust', clock.note];
    if (fromCache && cacheAge != null) {
      parts.add('读的是 ${humanAge(cacheAge!)}写入的缓存，不是刚拉的');
    } else {
      parts.add('拉取于 ${humanAge(DateTime.now().difference(fetchedAt))}');
    }
    if (fallbackReason != null) {
      parts.add('主源失败已降级：$fallbackReason');
    }
    return parts.join(' · ');
  }

  /// 存盘用：bars 压成数组，比对象省一半以上体积。
  /// `fetchedAt` 必须存：不然冷启动读缓存时，分不清这是刚拉的还是三天前的。
  Map<String, dynamic> toDisk() => {
    'symbol': symbol,
    'name': name,
    'period': period,
    'source': source,
    'fetchedAt': fetchedAt.toUtc().toIso8601String(),
    if (fallbackReason != null) 'fallbackReason': fallbackReason,
    'bars': [
      for (final b in bars) [b.t, b.o, b.h, b.l, b.c, b.v],
    ],
  };

  static KlineSeries? fromDisk(Map<String, dynamic> j) {
    final rows = j['bars'];
    if (rows is! List || rows.isEmpty) return null;
    final bars = <Bar>[];
    for (final r in rows) {
      if (r is! List || r.length < 6) continue;
      double? d(Object? v) => v is num ? v.toDouble() : double.tryParse('$v');
      final o = d(r[1]);
      final h = d(r[2]);
      final l = d(r[3]);
      final c = d(r[4]);
      if (o == null || h == null || l == null || c == null) continue;
      bars.add(Bar(o, h, l, c, v: d(r[5]) ?? 0, t: '${r[0]}'));
    }
    if (bars.isEmpty) return null;
    return KlineSeries(
      symbol: '${j['symbol'] ?? ''}',
      name: '${j['name'] ?? ''}',
      period: '${j['period'] ?? 'day'}',
      bars: bars,
      source: '${j['source'] ?? 'tencent'}',
      fallbackReason: j['fallbackReason']?.toString(),
      // 老缓存没有这个字段 → null，读出来会标成「拉取时间未知」
      fetchedAt: DateTime.tryParse('${j['fetchedAt'] ?? ''}'),
    );
  }

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
    this.pe,
    this.pb,
    this.turnover,
    this.floatCap,
    this.totalCap,
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

  /// 估值（腾讯快照里有，东财备源拿不到时为 null）。
  final double? pe;
  final double? pb;

  /// 换手率（%）
  final double? turnover;

  /// 流通市值 / 总市值，单位「亿」。
  final double? floatCap;
  final double? totalCap;

  double get change => price - prevClose;
  double get changePct => prevClose == 0 ? 0 : (price - prevClose) / prevClose * 100;
}

const _ua = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

/// 缠论取数建议根数：实测 400 根起结果收敛，腾讯日线最多约 640 根。
const int chanBarCount = 640;

/// 全局共享的数据源。
///
/// 面板、联动的搜索、AI 工具都走这一个实例——缓存和 TCP 连接才能真正复用。
StockSource? _shared;

/// 取全局数据源。
StockSource get sharedStockSource => _shared ??= StockSource();

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

  /// 拉 K 线。腾讯为主源（前复权），失败自动降级到新浪。
  ///
  /// [count] 默认 640（缠论建议值）。分钟线单次上限较低，会自动取实际返回。
  ///
  /// **为什么需要降级**：腾讯的 `web.ifzq` 域名曾经对 K 线接口返回 501
  /// （WAF 拦截），整个面板就刷不出图。多挂一个源，单点故障不至于全停。
  Future<KlineSeries> kline(String symbol, {String period = 'day', int count = chanBarCount}) async {
    final code = normalize(symbol);
    final p = normalizePeriod(period);

    // 三级降级：腾讯（前复权，最快最稳）→ 新浪（不复权）→ 东财（前复权，连接不稳）
    final errors = <String>[];
    for (final fetcher in <Future<KlineSeries> Function()>[
      () => _klineTencent(code, p, count),
      () => _klineSina(code, p, count),
      () => _klineEastmoney(code, p, count),
    ]) {
      try {
        final s = await fetcher();
        // 降级成功也要留痕：主源挂了这件事必须传到分析层，
        // 不然模型会把「新浪不复权数据」当成腾讯的连续序列来解读。
        return errors.isEmpty ? s : s.withFallback(errors.join('；'));
      } catch (e) {
        errors.add('$e');
      }
    }
    throw StockDataError('行情源都失败了：${errors.join('；')}');
  }

  // ------------------------------------------------------------ 东财（第三源）

  /// 东财 klt 参数。日/周/月是 101/102/103，分钟直接用数字。
  static const _emKlt = <String, int>{'day': 101, 'week': 102, 'month': 103, 'm60': 60, 'm30': 30, 'm15': 15, 'm5': 5};

  /// 东财 K 线（**前复权**，fqt=1）。
  ///
  /// 字段顺序与腾讯一致：`日期,开,收,高,低,量`，量单位也是「手」。
  /// 连接不太稳定（实测有约 1/3 概率连不上），所以排在最后。
  Future<KlineSeries> _klineEastmoney(String code, String p, int count) async {
    final klt = _emKlt[p];
    if (klt == null) throw StockDataError('东财源不支持周期 $p');

    // secid：沪市前缀 1，深市/北交所前缀 0
    final market = code.startsWith('sh') ? '1' : '0';
    final num = code.substring(2);
    final url =
        'https://push2his.eastmoney.com/api/qt/stock/kline/get'
        '?secid=$market.$num&fields1=f1,f2&fields2=f51,f52,f53,f54,f55,f56'
        '&klt=$klt&fqt=1&end=20500101&lmt=$count';

    final body = await _text(url, referer: 'https://quote.eastmoney.com/');
    final root = jsonDecode(body);
    final data = root is Map ? root['data'] : null;
    if (data is! Map) throw StockDataError('东财没有返回数据');

    final name = data['name']?.toString() ?? code;
    final rows = data['klines'];
    if (rows is! List || rows.isEmpty) throw StockDataError('东财没有 K 线数据');

    final bars = <Bar>[];
    for (final r in rows) {
      if (r is! String) continue;
      final f = r.split(',');
      if (f.length < 6) continue;
      final o = _d(f[1]);
      final c = _d(f[2]);
      final h = _d(f[3]);
      final l = _d(f[4]);
      final v = _d(f[5]);
      if (o == null || c == null || h == null || l == null) continue;
      bars.add(Bar(o, h, l, c, v: v ?? 0, t: f[0]));
    }
    if (bars.isEmpty) throw StockDataError('东财 K 线解析后为空');

    return KlineSeries(symbol: code, name: name, period: p, bars: bars, source: 'eastmoney');
  }

  // ------------------------------------------------------------ 腾讯（主源）

  Future<KlineSeries> _klineTencent(String code, String p, int count) async {
    // ★ 不能用 startsWith('m')：month 也以 m 开头，会被误判为分钟线走 mkline 接口。
    final isMinute = RegExp(r'^m\d+$').hasMatch(p);

    final String url;
    if (isMinute) {
      // 分钟线：必须 ifzq.gtimg.cn（web.ifzq 会 302 到 web3 超时）
      url = 'https://ifzq.gtimg.cn/appstock/app/kline/mkline?param=$code,$p,,,$count';
    } else {
      // 日/周/月线：param=code,period,,,count,qfq（4 个逗号是正确格式）
      // ★ 必须用 ifzq.gtimg.cn：web.ifzq 那个域名已经被腾讯 WAF 拦成 501 了
      url = 'https://ifzq.gtimg.cn/appstock/app/fqkline/get?param=$code,$p,,,$count,qfq';
    }

    // 腾讯接口偶发返回 param error / 空 data（抖动），重试一次再判失败。
    String body = '';
    dynamic root;
    for (var attempt = 0; attempt < 2; attempt++) {
      body = await _text(url);
      root = jsonDecode(body);
      if (root is Map && root['code'] == 0 && root['data'] is Map) break;
      if (attempt == 0) await Future<void>.delayed(const Duration(milliseconds: 400));
    }
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

  // ------------------------------------------------------------ 新浪（备源）

  /// 新浪 scale 参数：日 240 / 周 1200 / 月 7200，分钟直接用 5/15/30/60。
  static const _sinaScale = <String, int>{
    'day': 240,
    'week': 1200,
    'month': 7200,
    'm60': 60,
    'm30': 30,
    'm15': 15,
    'm5': 5,
  };

  /// 新浪 K 线（**不复权**）。
  ///
  /// 作为热备：字段名是显式的，不依赖 qfqday/day 这类命名猜测；
  /// 代价是不复权，除权日附近会有跳空，缠论可能因此多出假信号。
  /// 只在腾讯失败时使用，结果会在 `KlineSeries.source` 上标注。
  Future<KlineSeries> _klineSina(String code, String p, int count) async {
    final scale = _sinaScale[p];
    if (scale == null) throw StockDataError('新浪源不支持周期 $p');

    final url =
        'https://money.finance.sina.com.cn/quotes_service/api/json_v2.php/'
        'CN_MarketData.getKLineData?symbol=$code&scale=$scale&ma=no&datalen=$count';
    final body = await _text(url, referer: 'https://finance.sina.com.cn/');
    final trimmed = body.trim();
    if (trimmed.isEmpty || trimmed == 'null') {
      throw StockDataError('新浪返回空数据');
    }

    final list = jsonDecode(trimmed);
    if (list is! List || list.isEmpty) throw StockDataError('新浪返回格式异常');

    final bars = <Bar>[];
    for (final e in list) {
      if (e is! Map) continue;
      final t = e['day']?.toString() ?? '';
      final o = _d(e['open']);
      final h = _d(e['high']);
      final l = _d(e['low']);
      final c = _d(e['close']);
      // 新浪的量是「股」，腾讯是「手」，统一除以 100 好让指标口径一致
      final v = (_d(e['volume']) ?? 0) / 100;
      if (o == null || h == null || l == null || c == null) continue;
      bars.add(Bar(o, h, l, c, v: v, t: t));
    }
    if (bars.isEmpty) throw StockDataError('新浪 K 线解析后为空');

    return KlineSeries(symbol: code, name: code, period: p, bars: bars, source: 'sina');
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

  /// 宽容的数字解析。
  ///
  /// ★ 必须挡住 NaN / Infinity：`double.tryParse('NaN')` 是会成功的，
  ///   接口偶尔真会吐 "NaN" 这种值，一旦流进计算就会污染整列指标
  ///   （NaN 会顺着加减乘除传染，最后整个面板算不出东西）。
  static double? _d(Object? v) {
    if (v == null) return null;
    final d = v is num ? v.toDouble() : double.tryParse(v.toString());
    if (d == null) return null;
    return d.isFinite ? d : null;
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

    // 字段索引是实测出来的，不要凭印象改：
    //   [38] 换手率%  [39] 市盈率TTM  [44] 流通市值(亿)  [45] 总市值(亿)  [46] 市净率
    //
    // 估值这几个字段，0 要当成「没有」：ETF/指数的 PB 接口给的是 0.00，
    // 显示成 0 倍市盈率会误导（金融上不存在 0 倍）。
    double? ratio(int i) {
      final v = i < f.length ? _d(f[i]) : null;
      return (v == null || v == 0) ? null : v;
    }

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
      pe: ratio(39),
      pb: ratio(46),
      turnover: ratio(38),
      floatCap: ratio(44),
      totalCap: ratio(45),
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

  // ------------------------------------------------------------ 搜索

  /// 股票联想搜索。只返回可画 K 线的 A 股。
  Future<List<StockHit>> search(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return const [];
    final url = 'https://smartbox.gtimg.cn/s3/?v=2&q=${Uri.encodeQueryComponent(kw)}&t=all';
    final body = await _text(url, referer: 'https://gu.qq.com/');
    return parseSearchResponse(body);
  }

  // ------------------------------------------------------------ 分时

  /// 当天分时。必须带 `Referer: https://gu.qq.com/`。
  Future<MinuteSeries> minute(String symbol) async {
    final code = normalize(symbol);
    final url = 'https://ifzq.gtimg.cn/appstock/app/minute/query?code=$code';
    final body = await _text(url, referer: 'https://gu.qq.com/');
    final root = jsonDecode(body);
    if (root is! Map || root['code'] != 0) {
      throw StockDataError('分时接口返回异常');
    }
    final data = root['data'];
    if (data is! Map) throw StockDataError('分时返回里没有 data');
    final node = data[code];
    if (node is! Map) throw StockDataError('没有 $code 的分时数据');

    var name = code;
    final qt = node['qt'];
    if (qt is Map) {
      for (final v in qt.values) {
        if (v is List && v.length > 1) {
          name = v[1]?.toString() ?? code;
          break;
        }
      }
    }

    final inner = node['data'];
    if (inner is! Map) throw StockDataError('分时数据格式异常');
    final date = inner['date']?.toString() ?? '';
    final rows = inner['data'];
    if (rows is! List || rows.isEmpty) throw StockDataError('分时数据为空');

    final points = <MinutePoint>[];
    for (final r in rows) {
      if (r is! String) continue;
      final f = r.split(' ');
      if (f.length < 3) continue;
      final price = double.tryParse(f[1]);
      if (price == null) continue;
      points.add(MinutePoint(f[0], price, double.tryParse(f[2]) ?? 0, f.length > 3 ? (double.tryParse(f[3]) ?? 0) : 0));
    }
    if (points.isEmpty) throw StockDataError('分时数据解析后为空');

    // 昨收：优先用快照里的前收，拿不到就用分时第一根的价格兜底。
    // 快照走 quoteCache（60 秒），避免每次切到分时都多打一次请求。
    var prevClose = points.first.price;
    try {
      final q = await quoteCached(code);
      if (q.prevClose > 0) prevClose = q.prevClose;
    } catch (_) {
      // 拿不到就用首根，至少 0 轴位置不会崩
    }

    return MinuteSeries(symbol: code, name: name, date: date, points: points, prevClose: prevClose);
  }

  // ------------------------------------------------------------ 缓存

  static const _freshMs = 60000;
  static const _minuteFreshMs = 15000;
  static const _maxCache = 12;

  final Map<String, _CacheEntry> _cache = {};

  /// 三级缓存取 K 线：内存 → 磁盘 → 网络。
  ///
  /// 行为：
  ///  - 内存 1 分钟内新鲜 → 直接返回，不发请求
  ///  - 内存有旧值 / 磁盘有缓存 → **立刻返回旧数据**，同时后台刷新，
  ///    刷新完通过 [onRefresh] 推给界面。冷启动时用户先看到上次的图，
  ///    不用对着空屏等网络。
  ///  - 都没有 → 走网络（含三级降级），结果写内存和磁盘
  Future<KlineSeries> klineCached(
    String symbol, {
    String period = 'day',
    int count = chanBarCount,
    void Function(KlineSeries fresh)? onRefresh,
    void Function(String error)? onRefreshFailed,
  }) async {
    final code = normalize(symbol);
    final key = '$code|$period|$count';

    // 1) 内存命中且新鲜
    final hit = _cache[key];
    if (hit != null) {
      final age = _dataAge(hit.series!, hit.at);
      if (age.inMilliseconds < _freshMs) return hit.series!.asCached(age);
      // 2) 内存有旧值：先给旧的，后台刷新
      _refreshInBackground(key, code, period, count, onRefresh, onRefreshFailed);
      return hit.series!.asCached(age);
    }

    // 3) 磁盘缓存：先给旧的，后台刷新
    final disk = await _readDisk(code, period, count);
    if (disk != null) {
      _cache[key] = _CacheEntry(disk, DateTime.now());
      _refreshInBackground(key, code, period, count, onRefresh, onRefreshFailed);
      // 数据年龄按 **拉取时间** 算，不是按读盘时间算——
      // 否则冷启动读三天前的缓存也会显示成「刚更新」。
      return disk.asCached(_dataAge(disk, DateTime.now()));
    }

    // 4) 走网络
    final fresh = await kline(code, period: period, count: count);
    _put(key, fresh);
    unawaited(_writeDisk(code, period, count, fresh));
    return fresh;
  }

  /// 最近一次后台刷新失败的原因。null = 没失败过（或还没刷新过）。
  /// 界面读它来区分「实时数据」和「陈旧缓存」，不要自己猜。
  String? lastRefreshError;

  /// 数据年龄：以真实拉取时间为准，取不到就退回缓存写入时间。
  Duration _dataAge(KlineSeries s, DateTime fallbackAt) {
    final d = DateTime.now().difference(s.fetchedAt);
    if (d.isNegative || d.inDays > 3650) return DateTime.now().difference(fallbackAt);
    return d;
  }

  /// 后台刷新，不阻塞调用方。失败时记下原因（旧数据仍然可用），
  /// 但不把旧数据伪装成新的——[KlineSeries.fromCache] 已经标明它是缓存。
  void _refreshInBackground(
    String key,
    String code,
    String period,
    int count,
    void Function(KlineSeries)? onRefresh,
    void Function(String error)? onRefreshFailed,
  ) {
    unawaited(
      kline(code, period: period, count: count)
          .then((s) {
            _put(key, s);
            lastRefreshError = null;
            unawaited(_writeDisk(code, period, count, s));
            onRefresh?.call(s);
          })
          .catchError((Object e) {
            lastRefreshError = '$e';
            onRefreshFailed?.call('$e');
          }),
    );
  }

  // ------------------------------------------------------------ 磁盘缓存

  static const _diskMaxFiles = 40;

  /// 磁盘缓存的根目录。
  ///
  /// 默认 null = 不启用磁盘缓存。App 启动时设为 `AppPaths.support`，
  /// 这样这个文件不依赖 Flutter，纯 Dart 环境（测试、脚本）也能直接跑。
  static Directory? diskRoot;

  Directory? get _cacheDir {
    final root = diskRoot;
    return root == null ? null : Directory('${root.path}/stock_cache');
  }

  File? _diskFile(String code, String period, int count) {
    final dir = _cacheDir;
    return dir == null ? null : File('${dir.path}/${code}_${period}_$count.json');
  }

  Future<KlineSeries?> _readDisk(String code, String period, int count) async {
    try {
      final f = _diskFile(code, period, count);
      if (f == null || !await f.exists()) return null;
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return null;
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      return KlineSeries.fromDisk(j.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDisk(String code, String period, int count, KlineSeries s) async {
    try {
      final dir = _cacheDir;
      final f = _diskFile(code, period, count);
      if (dir == null || f == null) return;
      if (!await dir.exists()) await dir.create(recursive: true);
      // ★ tmp 名必须唯一：同一文件的两次并发写（比如后台刷新 + 前台保存）
      //   如果共用一个 .tmp，会互相覆盖，rename 时还可能拿到半个文件。
      final tmp = File('${f.path}.${nextTmpSeq()}.tmp');
      await tmp.writeAsString(jsonEncode(s.toDisk()), flush: true);
      await tmp.rename(f.path);
      unawaited(_pruneDisk(dir));
    } catch (_) {
      // 存不下来只影响下次冷启动，本次仍然可用
    }
  }

  /// 控制缓存文件数量，删最旧的。
  Future<void> _pruneDisk(Directory dir) async {
    try {
      final files = <(File, DateTime)>[];
      await for (final e in dir.list()) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        final st = await e.stat();
        files.add((e, st.modified));
      }
      if (files.length <= _diskMaxFiles) return;
      files.sort((a, b) => a.$2.compareTo(b.$2));
      for (var i = 0; i < files.length - _diskMaxFiles; i++) {
        await files[i].$1.delete();
      }
    } catch (_) {}
  }

  /// 清空磁盘缓存（设置页「清理缓存」用）。
  Future<void> clearDiskCache() async {
    try {
      final dir = _cacheDir;
      if (dir != null && await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  void _put(String key, KlineSeries s) {
    if (_cache.length >= _maxCache) {
      // 简单淘汰：删掉最早的
      String? oldestKey;
      DateTime? oldest;
      for (final e in _cache.entries) {
        if (oldest == null || e.value.at.isBefore(oldest)) {
          oldest = e.value.at;
          oldestKey = e.key;
        }
      }
      if (oldestKey != null) _cache.remove(oldestKey);
    }
    _cache[key] = _CacheEntry(s, DateTime.now());
  }

  final Map<String, _QuoteEntry> _quoteCache = {};

  final Map<String, _MinuteEntry> _minuteCache = {};

  /// 带缓存的分时。分时窗口收紧到 15 秒（盘中变化快）。
  Future<MinuteSeries> minuteCached(String symbol) {
    final key = normalize(symbol);
    final hit = _minuteCache[key];
    if (hit != null && DateTime.now().difference(hit.at).inMilliseconds < _minuteFreshMs) {
      return Future.value(hit.series);
    }
    return minute(key).then((m) {
      _minuteCache[key] = _MinuteEntry(m, DateTime.now());
      return m;
    });
  }

  /// 带缓存的实时快照。行情卡与分时共用，避免重复请求。
  Future<Quote> quoteCached(String symbol) {
    final key = normalize(symbol);
    final hit = _quoteCache[key];
    if (hit != null && DateTime.now().difference(hit.at).inMilliseconds < _freshMs) {
      return Future.value(hit.quote);
    }
    return quote(key).then((q) {
      _quoteCache[key] = _QuoteEntry(q, DateTime.now());
      return q;
    });
  }

  /// 缓存是否已过期到需要后台刷新（10 分钟内不算过期）。
  int get minuteFreshMs => _minuteFreshMs;

  // ------------------------------------------------------------ 基本面

  /// 东财 secid：沪市前缀 1，深市/北交所前缀 0。
  /// 东财 datacenter 的 SECUCODE：`300274.SZ` / `600519.SH` / `430047.BJ`。
  ///
  /// ★ 必须用 SECUCODE 而不是 SECURITY_CODE：后者不带市场，
  ///   `000001` 会同时匹配到上证指数和平安银行，指数被查出一堆财报数据。
  static String _emSecucode(String code) {
    final suffix = switch (code.substring(0, 2)) {
      'sh' => 'SH',
      'bj' => 'BJ',
      _ => 'SZ',
    };
    return '${code.substring(2)}.$suffix';
  }

  /// 取一只股票的估值、财报、龙虎榜。
  ///
  /// 三部分互相独立：某一部分失败不影响其他部分，失败原因记在 [Fundamental.note]。
  Future<Fundamental> fundamental(String symbol) async {
    final code = normalize(symbol);
    final results = await Future.wait([_valuation(code), _reports(code), _boards(code)]);
    final val = results[0] as Valuation?;
    final reports = results[1] as List<Report>;
    final boards = results[2] as List<BillBoard>;

    final notes = <String>[];
    if (val == null || val.isEmpty) notes.add('估值数据拿不到（涨幅/停牌原因，或该标的不适用）');
    if (reports.isEmpty) notes.add('没有财报数据（ETF、指数、或上市不足一期）');
    if (boards.isEmpty) notes.add('近期没有上龙虎榜记录');

    // 名称优先用财报里的，其次估值接口
    var name = code;
    try {
      final q = await quoteCached(code);
      if (q.name.isNotEmpty && q.name != code) name = q.name;
    } catch (_) {}

    return Fundamental(
      symbol: code,
      name: name,
      valuation: val,
      reports: reports,
      boards: boards,
      note: notes.isEmpty ? null : notes.join('；'),
    );
  }

  /// 估值。
  ///
  /// **从腾讯快照取**，不用东财 push2：后者实测会返回 502（服务端故障），
  /// 而腾讯快照本来就带这些字段，且和东财的数值一致
  /// （对比 300274：PB 都是 2.95、总市值都是 1459.7 亿）。
  Future<Valuation?> _valuation(String code) async {
    try {
      final q = await quoteCached(code);
      if (q.pe == null && q.pb == null && q.totalCap == null && q.floatCap == null) {
        return null;
      }
      return Valuation(
        pe: q.pe,
        pb: q.pb,
        // 腾讯给的单位是「亿」，统一换算成「元」方便和其他数字一起格式化
        totalCap: q.totalCap == null ? null : q.totalCap! * 1e8,
        floatCap: q.floatCap == null ? null : q.floatCap! * 1e8,
        turnover: q.turnover,
      );
    } catch (_) {
      return null;
    }
  }

  /// 财报。只取报告期口径的字段。
  Future<List<Report>> _reports(String code) async {
    try {
      // ★ 不能带 sortColumns=REPORT_DATE：该列不存在，接口会报 9501。
      //   默认返回已经按报告期倒序。
      final body = await _text(
        'https://datacenter-web.eastmoney.com/api/data/v1/get'
        '?reportName=RPT_LICO_FN_CPD&columns=ALL'
        '&filter=(SECUCODE%3D%22${_emSecucode(code)}%22)&pageSize=4&pageNumber=1',
      );
      final root = jsonDecode(body);
      final result = root is Map ? root['result'] : null;
      final rows = result is Map ? result['data'] : null;
      if (rows is! List) return const [];

      final out = <Report>[];
      for (final r in rows) {
        if (r is! Map) continue;
        final date = r['REPORTDATE']?.toString() ?? '';
        if (date.isEmpty) continue;
        out.add(
          Report(
            period: date.length >= 10 ? date.substring(0, 10) : date,
            eps: _d(r['BASIC_EPS']),
            revenue: _d(r['TOTAL_OPERATE_INCOME']),
            revenueYoy: _d(r['YSTZ']),
            netProfit: _d(r['PARENT_NETPROFIT']),
            netProfitYoy: _d(r['SJLTZ']),
            grossMargin: _d(r['XSMLL']),
            roe: _d(r['WEIGHTAVG_ROE']),
            bps: _d(r['BPS']),
            cashPerShare: _d(r['MGJYXJJE']),
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 龙虎榜。
  Future<List<BillBoard>> _boards(String code) async {
    try {
      final body = await _text(
        'https://datacenter-web.eastmoney.com/api/data/v1/get'
        '?reportName=RPT_DAILYBILLBOARD_DETAILSNEW&columns=ALL'
        '&filter=(SECUCODE%3D%22${_emSecucode(code)}%22)&pageSize=5'
        '&sortColumns=TRADE_DATE&sortTypes=-1',
      );
      final root = jsonDecode(body);
      final result = root is Map ? root['result'] : null;
      final rows = result is Map ? result['data'] : null;
      if (rows is! List) return const [];

      final out = <BillBoard>[];
      for (final r in rows) {
        if (r is! Map) continue;
        final date = r['TRADE_DATE']?.toString() ?? '';
        if (date.isEmpty) continue;
        out.add(
          BillBoard(
            date: date.length >= 10 ? date.substring(0, 10) : date,
            close: _d(r['CLOSE_PRICE']),
            changePct: _d(r['CHANGE_RATE']),
            buyAmt: _d(r['BILLBOARD_BUY_AMT']),
            sellAmt: _d(r['BILLBOARD_SELL_AMT']),
            dealAmt: _d(r['BILLBOARD_DEAL_AMT']),
            ratio: _d(r['DEAL_AMOUNT_RATIO']),
            reason: r['EXPLANATION']?.toString(),
            explain: r['EXPLAIN']?.toString(),
            next1: _d(r['D1_CLOSE_ADJCHRATE']),
            next2: _d(r['D2_CLOSE_ADJCHRATE']),
            next5: _d(r['D5_CLOSE_ADJCHRATE']),
            next10: _d(r['D10_CLOSE_ADJCHRATE']),
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
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

class _CacheEntry {
  _CacheEntry(this.series, this.at);

  final KlineSeries? series;
  final DateTime at;
}

class _QuoteEntry {
  _QuoteEntry(this.quote, this.at);

  final Quote quote;
  final DateTime at;
}

class _MinuteEntry {
  _MinuteEntry(this.series, this.at);

  final MinuteSeries series;
  final DateTime at;
}
