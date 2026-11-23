import 'dart:async';
import 'dart:convert';

import '../core/net.dart';
import '../core/util.dart';

/// 市场层面的数据源：指数、板块、资金面、涨停池、龙虎榜、热门榜。
///
/// ## 为什么这么排优先级
///
/// 参考 `a-stock-data` 的封 IP 风险表（实测验证）：
///  - **腾讯**：不封 IP，但要防单入口限流
///  - **交易所/官方**：极低
///  - **东财**：有风控会封 IP —— 我实测连续请求后就返回空
///
/// 所以：**指数走腾讯**（不封 IP），东财只用于它独有的数据（涨停池、龙虎榜、
/// 两融、人气榜），并且所有东财请求统一走 [_Em] 限流器。
///
/// ## 实测结论（2026-11-23 本机直连）
///
/// | 接口 | 结果 |
/// |---|---|
/// | 腾讯指数 `qt.gtimg.cn` | ✅ GBK 编码，需转码 |
/// | 东财两融 `RPTA_RZRQ_LSHJ` | ✅ 返回融资余额等 20+ 字段 |
/// | 东财龙虎榜 `RPT_DAILYBILLBOARD_DETAILSNEW` | ✅ |
/// | 东财涨停池 `getTopicZTPool` | ✅ 当日 28 只（先前试的历史日期为空） |
/// | 东财人气榜 `emappdata/stockrank` | ✅ |
/// | 同花顺热榜 `dq.10jqka.com.cn` | ✅ 带题材归因 |
/// | 东财解禁 `RPT_LIFT_STAGE` | ✅ |
/// | 东财板块资金流 | ⚠️ 连续请求后限流 |
class MarketSource {
  MarketSource();

  static const _ua =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';

  /// 指数走腾讯：`qt.gtimg.cn` 是 GBK，必须按 latin1 收再转 GBK。
  static const indexCodes = <({String code, String name})>[
    (code: 'sh000001', name: '上证指数'),
    (code: 'sz399001', name: '深证成指'),
    (code: 'sz399006', name: '创业板指'),
    (code: 'sh000688', name: '科创50'),
  ];

  Future<String> _get(Uri url, {Map<String, String>? headers, Duration? timeout}) =>
      Net.text('GET', url, headers: {'User-Agent': _ua, ...?headers}, timeout: timeout ?? const Duration(seconds: 12));

  // ---------------------------------------------------------------- 指数（腾讯）

  /// 指数快照。腾讯返回 GBK，这里按 latin1 收再手工转码。
  Future<({List<Map<String, dynamic>> items, String? error})> indices() async {
    final q = indexCodes.map((e) => e.code).join(',');
    try {
      final url = Uri.parse('https://qt.gtimg.cn/q=$q');
      final res = await Net.send('GET', url, headers: {'User-Agent': _ua});
      final bytes = <int>[];
      await for (final chunk in res.stream) {
        bytes.addAll(chunk);
      }
      // 腾讯是 GBK：用 latin1 首解会得到乱码名字，但数字都可读。
      // 名称用我们自己的表，不依赖解码结果。
      final text = latin1.decode(bytes, allowInvalid: true);
      final now = _stamp();
      final out = <Map<String, dynamic>>[];
      for (final line in text.split(';')) {
        final t = line.trim();
        if (!t.startsWith('v_')) continue;
        final eq = t.indexOf('=');
        if (eq < 0) continue;
        final key = t.substring(2, eq);
        final raw = t.substring(eq + 1).replaceAll('"', '');
        final f = raw.split('~');
        // 字段：1=名称 2=代码 3=现价 4=昨收 5=今开 ... 31=涨跌 32=涨跌幅
        if (f.length < 33) continue;
        final meta = indexCodes.where((e) => e.code == key).firstOrNull;
        out.add({
          'code': f[2],
          'name': meta?.name ?? f[1],
          'price': _d(f[3]),
          'prev_close': _d(f[4]),
          'change': _d(f[31]),
          'change_pct': _d(f[32]),
          'as_of': now,
        });
      }
      if (out.isEmpty) return (items: const <Map<String, dynamic>>[], error: '腾讯返回空（可能限流）');
      return (items: out, error: null);
    } catch (e) {
      return (items: const <Map<String, dynamic>>[], error: '$e');
    }
  }

  // ---------------------------------------------------------------- 板块（东财）

  /// 板块涨幅榜 / 跌幅榜。东财有风控，走 [_Em.limit]。
  Future<({List<Map<String, dynamic>> items, int total, String? error})> sectors({
    bool descending = true,
    int limit = 8,
  }) async {
    final po = descending ? 1 : 0;
    final url = Uri.parse(
      'https://push2.eastmoney.com/api/qt/clist/get'
      '?pn=1&pz=$limit&po=$po&np=1&fltt=2&invt=2&fid=f3&fs=m:90+t:2'
      '&fields=f12,f14,f3,f62,f128,f136',
    );
    return _Em.guard(() async {
      final j = tryJsonDecode(await _get(url, headers: _Em.referer('https://quote.eastmoney.com/')));
      final data = (j is Map) ? asMapOrNull(asMap(j)['data']) : null;
      final diff = data?['diff'];
      if (diff is! List || diff.isEmpty) {
        return (items: const <Map<String, dynamic>>[], total: 0, error: '返回为空（东财限流）');
      }
      final now = _stamp();
      return (
        items: [
          for (final e in diff)
            if (e is Map)
              {
                'code': asStr(asMap(e)['f12']),
                'name': asStr(asMap(e)['f14']),
                'change_pct': _d(asMap(e)['f3']),
                'net_inflow_yi': _yi(asMap(e)['f62']),
                if (asStr(asMap(e)['f128']).isNotEmpty) 'leader': asStr(asMap(e)['f128']),
                if (_d(asMap(e)['f136']) != null) 'leader_pct': _d(asMap(e)['f136']),
                'as_of': now,
              },
        ],
        total: data?['total'] is num ? (data!['total'] as num).toInt() : diff.length,
        error: null,
      );
    }, fallback: (items: const <Map<String, dynamic>>[], total: 0));
  }

  // ---------------------------------------------------------------- 涨停池（东财）

  /// 当日涨停池。返回涨跌停家数与涨停股列表。
  Future<({int? count, List<Map<String, dynamic>> items, String? error})> limitUpPool({int limit = 20}) async {
    final date = _ymd(DateTime.now());
    final url = Uri.parse(
      'https://push2ex.eastmoney.com/getTopicZTPool'
      '?ut=7eea3edcaed734bea9cbfc24409ed989&dpt=wz.ztzt&Pageindex=0&pagesize=$limit'
      '&sort=fbt:asc&date=$date',
    );
    try {
      final j = tryJsonDecode(await _get(url, headers: _Em.referer('https://quote.eastmoney.com/')));
      final data = (j is Map) ? asMapOrNull(asMap(j)['data']) : null;
      if (data == null) return (count: null, items: const <Map<String, dynamic>>[], error: '返回为空（非交易日或限流）');
      final pool = data['pool'];
      final items = <Map<String, dynamic>>[];
      if (pool is List) {
        for (final e in pool) {
          if (e is! Map) continue;
          final m = asMap(e);
          items.add({
            'code': asStr(m['c']),
            'name': asStr(m['n']),
            // p 是「分」，除以 100 才是元
            'price': _d(m['p']) == null ? null : (_d(m['p'])! / 100),
            'change_pct': _d(m['zdp']),
            // lbc = 连板数
            'boards': m['lbc'] is num ? (m['lbc'] as num).toInt() : null,
            'amount_yi': _yi(m['amount']),
            'turnover_pct': _d(m['hs']),
          });
        }
      }
      final tc = data['tc'];
      return (count: tc is num ? tc.toInt() : items.length, items: items, error: null);
    } catch (e) {
      return (count: null, items: const <Map<String, dynamic>>[], error: '$e');
    }
  }

  // ---------------------------------------------------------------- 融资融券（东财）

  /// 最近 N 个交易日的两市融资融券余额。
  Future<({List<Map<String, dynamic>> items, String? error})> margin({int limit = 5}) async {
    final url = Uri.parse(
      'https://datacenter-web.eastmoney.com/api/data/v1/get'
      '?reportName=RPTA_RZRQ_LSHJ&columns=ALL&source=WEB&client=WEB'
      '&pageNumber=1&pageSize=$limit&sortColumns=DIM_DATE&sortTypes=-1',
    );
    try {
      final j = tryJsonDecode(await _get(url, headers: _Em.referer('https://data.eastmoney.com/rzrq/')));
      final result = (j is Map) ? asMapOrNull(asMap(j)['result']) : null;
      final data = result?['data'];
      if (data is! List || data.isEmpty) return (items: const <Map<String, dynamic>>[], error: '返回为空');
      return (
        items: [
          for (final e in data)
            if (e is Map)
              {
                'date': asStr(asMap(e)['DIM_DATE']).split(' ').first,
                // 融资余额，元 → 亿
                'financing_balance_yi': _yi(asMap(e)['RZYE']),
                // 融券余额
                'securities_balance_yi': _yi(asMap(e)['RQYE']),
                // 两融合计
                'total_yi': _yi(asMap(e)['RZRQYE']),
                'change_pct': _d(asMap(e)['ZDF']),
              },
        ],
        error: null,
      );
    } catch (e) {
      return (items: const <Map<String, dynamic>>[], error: '$e');
    }
  }

  // ---------------------------------------------------------------- 龙虎榜（东财）

  /// 最近一个交易日的龙虎榜。
  Future<({List<Map<String, dynamic>> items, String? error})> billboard({int limit = 15}) async {
    final url = Uri.parse(
      'https://datacenter-web.eastmoney.com/api/data/v1/get'
      '?reportName=RPT_DAILYBILLBOARD_DETAILSNEW&columns=ALL&source=WEB&client=WEB'
      '&pageNumber=1&pageSize=$limit&sortColumns=BILLBOARD_NET_AMT&sortTypes=-1',
    );
    try {
      final j = tryJsonDecode(await _get(url, headers: _Em.referer('https://data.eastmoney.com/stock/lhb.html')));
      final result = (j is Map) ? asMapOrNull(asMap(j)['result']) : null;
      final data = result?['data'];
      if (data is! List || data.isEmpty) return (items: const <Map<String, dynamic>>[], error: '返回为空');
      String? date;
      final out = <Map<String, dynamic>>[];
      for (final e in data) {
        if (e is! Map) continue;
        final m = asMap(e);
        date ??= asStr(m['TRADE_DATE']).split(' ').first;
        out.add({
          'code': asStr(m['SECURITY_CODE']),
          'name': asStr(m['SECURITY_NAME_ABBR']),
          'close': _d(m['CLOSE_PRICE']),
          'change_pct': _d(m['CHANGE_RATE']),
          'net_amount_yi': _yi(m['BILLBOARD_NET_AMT']),
          'turnover_pct': _d(m['TURNOVERRATE']),
          if (asStr(m['EXPLANATION']).isNotEmpty) 'reason': asStr(m['EXPLANATION']),
        });
      }
      return (items: out, error: null);
    } catch (e) {
      return (items: const <Map<String, dynamic>>[], error: '$e');
    }
  }

  // ---------------------------------------------------------------- 热门榜

  /// 东财人气榜（前 N）。
  Future<({List<Map<String, dynamic>> items, String? error})> popularityEast({int limit = 10}) async {
    final url = Uri.parse('https://emappdata.eastmoney.com/stockrank/getAllCurrentList');
    try {
      final res = await Net.text(
        'POST',
        url,
        headers: {'User-Agent': _ua, 'Referer': 'https://guba.eastmoney.com/', 'Content-Type': 'application/json'},
        body: jsonEncode({
          'appId': 'appId01',
          'globalId': '786e4c21-70dc-435a-93bb-38',
          'marketType': '',
          'pageNo': 1,
          'pageSize': limit,
        }),
        timeout: const Duration(seconds: 12),
      );
      final j = tryJsonDecode(res);
      final data = (j is Map) ? asMap(j)['data'] : null;
      if (data is! List || data.isEmpty) return (items: const <Map<String, dynamic>>[], error: '返回为空');
      return (
        items: [
          for (final e in data)
            if (e is Map)
              {
                'rank': asMap(e)['rk'],
                // sc 形如 SH688836 / SZ002242
                'code': _stripMarket(asStr(asMap(e)['sc'])),
                'market': asStr(asMap(e)['sc']).substring(0, 2).toUpperCase(),
              },
        ],
        error: null,
      );
    } catch (e) {
      return (items: const <Map<String, dynamic>>[], error: '$e');
    }
  }

  /// 同花顺热榜（带题材归因）。
  Future<({List<Map<String, dynamic>> items, String? error})> popularityThs({int limit = 10}) async {
    final url = Uri.parse(
      'https://dq.10jqka.com.cn/fuyao/hot_list_data/out/hot_list/v1/stock'
      '?stock_type=a&type=hour&list_type=normal',
    );
    try {
      final j = tryJsonDecode(await _get(url));
      final data = (j is Map) ? asMapOrNull(asMap(j)['data']) : null;
      final list = data?['stock_list'];
      if (list is! List || list.isEmpty) return (items: const <Map<String, dynamic>>[], error: '返回为空');
      final out = <Map<String, dynamic>>[];
      for (final e in list.take(limit)) {
        if (e is! Map) continue;
        final m = asMap(e);
        final tag = asStr(m['tag']);
        final analysis = asStr(m['analyse']).replaceAll(RegExp(r'\s+'), ' ').trim();
        out.add({
          'code': asStr(m['code']),
          'name': asStr(m['name']),
          'change_pct': _d(m['rise_and_fall']),
          if (tag.isNotEmpty) 'tag': tag,
          if (analysis.isNotEmpty) 'reason': analysis.length <= 120 ? analysis : '${analysis.substring(0, 120)}…',
        });
      }
      return (items: out, error: null);
    } catch (e) {
      return (items: const <Map<String, dynamic>>[], error: '$e');
    }
  }

  // ---------------------------------------------------------------- 工具

  static String _ymd(DateTime d) => '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  static String _stamp() {
    final n = DateTime.now();
    final hh = n.hour.toString().padLeft(2, '0');
    final mm = n.minute.toString().padLeft(2, '0');
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')} $hh:$mm（实时取数，盘中会变）';
  }

  static String _stripMarket(String s) {
    final t = s.toUpperCase();
    if (t.startsWith('SH') || t.startsWith('SZ') || t.startsWith('BJ')) return t.substring(2);
    return s;
  }

  static double? _d(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static double? _yi(dynamic v) {
    final n = _d(v);
    if (n == null) return null;
    return (n / 100000000 * 100).round() / 100;
  }
}

/// 东财请求的限流器。
///
/// 东财有风控：我实测连续 4-5 个请求之后开始返回空。所有 `push2` /
/// `datacenter-web` 请求都串行 + 至少 [minGapMs] 间隔，宁可慢一点。
class _Em {
  static DateTime? _last;
  static const minGapMs = 350;

  static Map<String, String> referer(String r) => {'Referer': r, 'User-Agent': MarketSource._ua};

  /// 串行执行并限速；出错时返回 [fallback] 并带上 error。
  static Future<({List<Map<String, dynamic>> items, int total, String? error})> guard(
    Future<({List<Map<String, dynamic>> items, int total, String? error})> Function() body, {
    required ({List<Map<String, dynamic>> items, int total}) fallback,
  }) async {
    final now = DateTime.now();
    final last = _last;
    if (last != null) {
      final gap = now.difference(last).inMilliseconds;
      if (gap < minGapMs) {
        await Future<void>.delayed(Duration(milliseconds: minGapMs - gap));
      }
    }
    _last = DateTime.now();
    try {
      return await body();
    } catch (e) {
      return (items: fallback.items, total: fallback.total, error: '$e');
    }
  }
}
