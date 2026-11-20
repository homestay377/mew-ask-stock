/// 股票搜索：`smartbox.gtimg.cn` 联想接口。
///
/// 返回格式（实测）：
/// ```
/// v_hint="sz~300274~\u9633\u5149\u7535\u6e90~ygdy~GP-A^sh~600261~...~GP-A^..."
/// ```
/// 每项 `市场~代码~名称~拼音~类型`，多项用 `^` 分隔，名称是 `\uXXXX` 转义。
library;

/// 一条搜索结果。
class StockHit {
  StockHit({required this.market, required this.code, required this.name, required this.pinyin, required this.type});

  /// `sz` / `sh` / `bj` / `hk` / `us`
  final String market;
  final String code;
  final String name;
  final String pinyin;

  /// `GP-A` / `GP-A-KCB` / `GP`（港股）/ `GP-FUND-REITS` 等
  final String type;

  /// 腾讯用的完整代码，如 `sz300274`。
  String get fullCode => '$market$code';

  /// 是否是可画 K 线的 A 股。港股/美股/基金的字段口径不同，面板不接。
  bool get isAShare => (market == 'sz' || market == 'sh' || market == 'bj') && type.startsWith('GP-A');

  String get display => '$name $code';
}

/// 解析 `v_hint="..."` 的原始响应。
///
/// [aShareOnly] 为 true 时只保留 A 股（面板用）。
List<StockHit> parseSearchResponse(String body, {bool aShareOnly = true}) {
  final m = RegExp(r'v_hint="([\s\S]*)"').firstMatch(body);
  if (m == null) return const [];
  final raw = m.group(1)!.trim();
  if (raw.isEmpty) return const [];

  final out = <StockHit>[];
  for (final item in raw.split('^')) {
    final f = item.split('~');
    if (f.length < 4) continue;
    final hit = StockHit(
      market: f[0],
      code: f[1],
      name: _unescapeUnicode(f[2]),
      pinyin: f[3],
      type: f.length > 4 ? f[4] : '',
    );
    if (aShareOnly && !hit.isAShare) continue;
    if (hit.code.length != 6) continue;
    out.add(hit);
  }
  return out;
}

/// 把 `\u9633\u5149` 还原成中文。
String _unescapeUnicode(String s) {
  if (!s.contains(r'\u')) return s;
  return s.replaceAllMapped(RegExp(r'\\u([0-9a-fA-F]{4})'), (m) {
    return String.fromCharCode(int.parse(m.group(1)!, radix: 16));
  });
}
