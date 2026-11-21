import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/stock/chart_shapes.dart';

/// 画线按天失效的回归。
///
/// 背景：画线坐标是「第几根 K 线索引」，而面板取的是滚动窗口。
/// 新的一天进来一根，所有索引整体后移，旧线会漂到别的 K 线上。
/// 所以整组按「画线时最后一根的日期」打标，跨日即作废；一键擦除是手动兜底。
void main() {
  final sample = ChartShape(kind: ShapeKind.hline, i1: 639, p1: 68.5, color: ShapeColor.support);

  test('序列化往返不丢字段', () {
    final bundle = ShapeBundle(shapes: [sample], barDate: '2026-11-20');
    final back = ShapeBundle.fromJson(bundle.toJson());
    expect(back, isNotNull);
    expect(back!.barDate, '2026-11-20');
    expect(back.shapes.length, 1);
    expect(back.shapes.first.kind, ShapeKind.hline);
    expect(back.shapes.first.i1, 639);
    expect(back.shapes.first.p1, 68.5);
    expect(back.shapes.first.color, ShapeColor.support);
  });

  test('同一天可用、换一天作废', () {
    final bundle = ShapeBundle(shapes: [sample], barDate: '2026-11-20');
    expect(bundle.staleFor('2026-11-20'), isFalse);
    expect(bundle.staleFor('2026-11-21'), isTrue);
  });

  test('拿不到当前日期时不做判断（宁可留着也别清空用户图）', () {
    final bundle = ShapeBundle(shapes: [sample], barDate: '2026-11-20');
    expect(bundle.staleFor(null), isFalse);
  });

  test('旧格式（没有日期）判为过期，但图元仍能读出来', () {
    final legacy = ShapeBundle.fromLegacyList([sample.toJson()]);
    expect(legacy.barDate, isNull);
    expect(legacy.shapes.length, 1);
    expect(legacy.staleFor('2026-11-20'), isTrue, reason: '旧坐标已经跟着滚动窗口位移，不能再画');
  });

  test('分钟线：同一天里新走完一根就作废（索引同样会位移）', () {
    final b = ShapeBundle(shapes: [sample], barDate: '2026-11-20', barStamp: '202611201400');
    expect(b.staleFor('2026-11-20', currentStamp: '202611201400', intraday: true), isFalse, reason: '同一根上还能用');
    expect(b.staleFor('2026-11-20', currentStamp: '202611201500', intraday: true), isTrue, reason: '新走完一根就该清');
    // 日线不看时间戳：同一天内不会因为别的原因失效
    expect(b.staleFor('2026-11-20', currentStamp: '202611201500'), isFalse);
  });

  test('坏数据不抛异常', () {
    expect(ShapeBundle.fromJson({'shapes': 'oops'}), isNull);
    expect(ShapeBundle.fromJson(null), isNull);
    expect(ShapeBundle.fromJson({'shapes': []})!.shapes, isEmpty);
  });
}
