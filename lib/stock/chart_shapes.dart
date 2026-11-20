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
