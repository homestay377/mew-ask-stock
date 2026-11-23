import '../core/net.dart';
import '../core/util.dart';

/// 市场层面的数据源：指数、板块强弱、资金流向。
///
/// 只做**实测可用**的接口，取不到就明确返回 unavailable，绝不用估计值填充。
///
/// 实测结论（2026-11-23，本机直连）：
///  - 指数（`push2.eastmoney.com/api/qt/ulist.np/get`）：可用
///  - 板块涨幅榜 + 主力净流入（`clist/get` + `fs=m:90+t:2`）：可用
///  - 涨停池（`push2ex.eastmoney.com/getTopicZTPool`）：接口有响应，但当日返回空池，
///    未验证可靠，先不提供
///  - 涨跌家数：`fs` 参数组合未能验证通过，不提供
///
/// 这些接口都是非官方免费接口，没有 SLA，可能限流。限流时返回明确的错误，
/// 让模型如实说「取不到」，而不是编一个数字。
class MarketSource {
  static const _referer = 'https://quote.eastmoney.com/';
  static const _ua =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';

  /// 常用指数。
  static const indices = <({String secid, String code, String name})>[
    (secid: '1.000001', code: '000001', name: '上证指数'),
    (secid: '0.399001', code: '399001', name: '深证成指'),
    (secid: '0.399006', code: '399006', name: '创业板指'),
    (secid: '1.000688', code: '000688', name: '科创50'),
  ];

  Map<String, String> get _headers => {'Referer': _referer, 'User-Agent': _ua};

  /// 指数快照。返回的每一项都带 `as_of`（取数时间）。
  Future<({List<Map<String, dynamic>> items, String? error})> indexSnapshot() async {
    final ids = indices.map((e) => e.secid).join(',');
    final uri = Uri.parse(
      'https://push2.eastmoney.com/api/qt/ulist.np/get'
      '?fltt=2&secids=$ids&fields=f12,f14,f2,f3,f4',
    );
    try {
      final text = await Net.text('GET', uri, headers: _headers, timeout: const Duration(seconds: 12));
      final j = tryJsonDecode(text);
      if (j is! Map) return (items: const <Map<String, dynamic>>[], error: '返回不是 JSON');
      final data = asMapOrNull(j['data']);
      final diff = data?['diff'];
      if (diff is! List || diff.isEmpty) return (items: const <Map<String, dynamic>>[], error: '返回为空（可能被限流）');
      final now = DateTime.now();
      final out = <Map<String, dynamic>>[];
      for (final e in diff) {
        if (e is! Map) continue;
        final m = asMap(e);
        out.add({
          'code': asStr(m['f12']),
          'name': asStr(m['f14']),
          'price': _num(m['f2']),
          'change_pct': _num(m['f3']),
          'change': _num(m['f4']),
        });
      }
      return (
        items: [
          for (final i in out) {...i, 'as_of': _stamp(now, i['price'], i['change_pct'])},
        ],
        error: null,
      );
    } catch (e) {
      return (items: const <Map<String, dynamic>>[], error: '$e');
    }
  }

  /// 板块涨幅榜。`descending=true` 取涨幅前列，`false` 取跌幅前列。
  ///
  /// 返回字段：代码（BKxxxx）、名称、涨跌幅、主力净流入（元）。
  Future<({List<Map<String, dynamic>> items, int total, String? error})> sectors({
    bool descending = true,
    int limit = 10,
  }) async {
    final po = descending ? 1 : 0;
    final uri = Uri.parse(
      'https://push2.eastmoney.com/api/qt/clist/get'
      '?pn=1&pz=$limit&po=$po&np=1&fltt=2&invt=2&fid=f3&fs=m:90+t:2'
      '&fields=f12,f14,f3,f62,f104,f105,f128,f136',
    );
    try {
      final text = await Net.text('GET', uri, headers: _headers, timeout: const Duration(seconds: 12));
      final j = tryJsonDecode(text);
      if (j is! Map) return (items: const <Map<String, dynamic>>[], total: 0, error: '返回不是 JSON');
      final data = asMapOrNull(j['data']);
      final diff = data?['diff'];
      if (diff is! List || diff.isEmpty) {
        return (items: const <Map<String, dynamic>>[], total: 0, error: '返回为空（可能被限流）');
      }
      final total = data?['total'] is num ? (data!['total'] as num).toInt() : diff.length;
      final now = DateTime.now();
      final out = <Map<String, dynamic>>[];
      for (final e in diff) {
        if (e is! Map) continue;
        final m = asMap(e);
        out.add({
          'code': asStr(m['f12']),
          'name': asStr(m['f14']),
          'change_pct': _num(m['f3']),
          // 主力净流入，单位元；转换成亿便于阅读
          'net_inflow_yi': _yi(m['f62']),
          // 领涨股
          if (asStr(m['f128']).isNotEmpty) 'leader': asStr(m['f128']),
          if (_num(m['f136']) != null) 'leader_pct': _num(m['f136']),
          'as_of': _stamp(now, null, null),
        });
      }
      return (items: out, total: total, error: null);
    } catch (e) {
      return (items: const <Map<String, dynamic>>[], total: 0, error: '$e');
    }
  }

  double? _num(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  /// 元 → 亿。
  double? _yi(dynamic v) {
    final n = _num(v);
    if (n == null) return null;
    return (n / 100000000 * 100).round() / 100;
  }

  /// `as_of` 用「时间 + 当时的数值指纹」，让模型能判断这份数据新不新。
  String _stamp(DateTime now, dynamic price, dynamic pct) {
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '$hh:$mm（实时取数，盘中会变）';
  }
}
