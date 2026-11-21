/// 用户手动画的图层：水平线、趋势线、射线、矩形、文字、箭头、圆点。
///
/// 与 Eta 的 `shapes.js` 同构：
///  - 坐标存「K 线索引 + 价格」，不存像素，所以缩放/平移后不会飘
///  - 画线按「代码 + 周期」分别保存
library;

/// 图元类型。
enum ShapeKind { hline, trendline, ray, rect, text, arrow, dot }

/// 语义颜色键，对应主题里的实际色值。
enum ShapeColor { up, down, resist, support, stop, target, accent }

ShapeKind? shapeKindFromName(String n) {
  for (final k in ShapeKind.values) {
    if (k.name == n) return k;
  }
  return null;
}

ShapeColor shapeColorFromName(String n) {
  for (final c in ShapeColor.values) {
    if (c.name == n) return c;
  }
  return ShapeColor.accent;
}

/// 一个图元实例。
class ChartShape {
  ChartShape({
    required this.kind,
    required this.i1,
    required this.p1,
    this.i2,
    this.p2,
    this.text,
    this.color = ShapeColor.accent,
  });

  final ShapeKind kind;

  /// 起点：K 线索引
  final int i1;

  /// 起点：价格
  final double p1;

  /// 终点（hline / text / dot 为 null）
  final int? i2;
  final double? p2;
  final String? text;
  final ShapeColor color;

  ChartShape copyWith({int? i1, double? p1, int? i2, double? p2, String? text, ShapeColor? color}) => ChartShape(
    kind: kind,
    i1: i1 ?? this.i1,
    p1: p1 ?? this.p1,
    i2: i2 ?? this.i2,
    p2: p2 ?? this.p2,
    text: text ?? this.text,
    color: color ?? this.color,
  );

  Map<String, dynamic> toJson() => {
    'k': kind.name,
    'i1': i1,
    'p1': p1,
    if (i2 != null) 'i2': i2,
    if (p2 != null) 'p2': p2,
    if (text != null) 't': text,
    'c': color.name,
  };

  static ChartShape fromJson(Map<String, dynamic> j) => ChartShape(
    kind: shapeKindFromName('${j['k']}') ?? ShapeKind.hline,
    i1: (j['i1'] as num?)?.toInt() ?? 0,
    p1: (j['p1'] as num?)?.toDouble() ?? 0,
    i2: (j['i2'] as num?)?.toInt(),
    p2: (j['p2'] as num?)?.toDouble(),
    text: j['t']?.toString(),
    color: shapeColorFromName('${j['c']}'),
  );
}

/// 一组画线，以及这组线是「哪一根 K 线」上画的。
///
/// 为什么需要锚点：画线坐标是 **K 线索引**（第几根），而面板取的是滚动窗口
/// （640 根）。新的一根进来、最老的一根滚出去，所有索引整体位移，
/// 于是「上周画的压力线」会跑到别的 K 线上，看着像画错了。
///
/// 处理方式：整组按画线时的锚点打标，锚点变了整组作废（不逐根重定位）。
/// AI 画的支撑压力本来就是针对当下结构的判断，行情走了一天就该重新画。
class ShapeBundle {
  ShapeBundle({required this.shapes, this.barDate, this.barStamp});

  final List<ChartShape> shapes;

  /// `yyyy-MM-dd`。null 表示旧版本数据（那时候还没记录日期）。
  final String? barDate;

  /// 画线时最后一根的原始时间戳（日线是 `2026-11-20`，分钟是 `202611201400`）。
  /// 分钟线靠它判：同一天里新走完一根，索引同样会位移。
  final String? barStamp;

  bool get isEmpty => shapes.isEmpty;

  /// 这份数据在当前这一根 K 线上还能不能用。
  ///
  /// - 日/周/月：按日期判，跨日即作废（一天才走一根，日期足够）
  /// - 分钟线（[intraday]）：同一天内每走完一根索引就位移一次，所以按原始
  ///   时间戳判，出现任何新 K 线都作废
  ///
  /// 日期与时间戳都拿不到时不做判断、保持原样——宁可显示旧线，
  /// 也不要因为算不出来就把用户的图清空。
  bool staleFor(String? currentBarDate, {String? currentStamp, bool intraday = false}) {
    if (currentBarDate == null && currentStamp == null) return false;
    // 旧格式没记日期：里面全是滚动窗口下已经错位的坐标，直接判过期
    final d = barDate;
    if (d == null) return true;
    if (currentBarDate != null && d != currentBarDate) return true;
    if (!intraday) return false;
    final a = barStamp;
    if (a == null || currentStamp == null) return false;
    return a != currentStamp;
  }

  Map<String, dynamic> toJson() => {
    if (barDate != null) 'date': barDate,
    if (barStamp != null) 'bar': barStamp,
    'shapes': [for (final s in shapes) s.toJson()],
  };

  /// 只接受新格式；旧格式（直接是数组）由 ShapeStore 按「过期」处理。
  static ShapeBundle? fromJson(Object? j) {
    if (j is! Map) return null;
    final rows = j['shapes'];
    if (rows is! List) return null;
    return ShapeBundle(
      barDate: j['date']?.toString(),
      barStamp: j['bar']?.toString(),
      shapes: [
        for (final x in rows)
          if (x is Map) ChartShape.fromJson(x.cast<String, dynamic>()),
      ],
    );
  }

  /// 旧格式迁移：列表 → bundle，日期留空（读取时会被判为过期）。
  static ShapeBundle fromLegacyList(List<dynamic> rows) => ShapeBundle(
    shapes: [
      for (final x in rows)
        if (x is Map) ChartShape.fromJson(x.cast<String, dynamic>()),
    ],
  );
}
