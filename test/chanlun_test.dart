import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/stock/chanlun.dart';

/// 缠论引擎回归测试。
///
/// 基准数据来自 `chanlun_engine`（Python 参考实现）与通达信真机验收：
/// 300274 日线 640 根 → 38 笔 / 4 中枢，中枢边界与通达信截图逐值一致
/// （`下线=72.42`、红 183.86/158.95、绿 140.80/123.49）。
///
/// 这些数字是整条链路最硬的验收标准：公式解释器、窗口长度、合并口径任何一处出错都会对不上。
void main() {
  late List<Bar> bars;
  late String formula;

  setUpAll(() {
    final goldenFile = File('test/fixtures/chan/golden_300274.json');
    final formulaFile = File('test/fixtures/chan/chan_formula.txt');
    final golden = jsonDecode(goldenFile.readAsStringSync()) as Map<String, dynamic>;
    formula = formulaFile.readAsStringSync();
    bars = [
      for (final b in golden['bars'] as List)
        Bar(
          (b['o'] as num).toDouble(),
          (b['h'] as num).toDouble(),
          (b['l'] as num).toDouble(),
          (b['c'] as num).toDouble(),
          v: (b['v'] as num?)?.toDouble() ?? 0.0,
          t: b['dt'] as String? ?? '',
        ),
    ];
  });

  test('640 根 K 线解析出 38 笔，逐值一致', () {
    final r = Chanlun.analyze(bars, formula);
    expect(r.pens.length, 38);
    expect(r.pens.first.idx, 0);
    expect(r.pens.first.price, closeTo(71.346, 1e-6));
    expect(r.pens.last.type, '底');
    expect(r.pens.last.price, closeTo(72.99, 1e-6));
  });

  test('4 个中枢，边界与通达信一致', () {
    final r = Chanlun.analyze(bars, formula);
    expect(r.boxes.length, 4);

    expect(r.boxes[0].tag, '绿');
    expect(r.boxes[0].s, 1);
    expect(r.boxes[0].e, 248);
    expect(r.boxes[0].zg, closeTo(71.346, 1e-6));
    expect(r.boxes[0].zd, closeTo(68.48, 1e-6));

    // 通达信截图里的两个中枢
    expect(r.boxes[2].zg, closeTo(183.86, 1e-6));
    expect(r.boxes[2].zd, closeTo(158.95, 1e-6));
    expect(r.boxes[3].zg, closeTo(140.80, 1e-6));
    expect(r.boxes[3].zd, closeTo(123.49, 1e-6));
  });

  test('公式零错误，关键中间序列全部产出', () {
    final r = Chanlun.analyze(bars, formula);
    expect(r.errors, isEmpty);
    for (final key in ['X_70', 'X_71', '红起', '绿起', '红顶_锁定', '绿底_锁定']) {
      expect(r.data.containsKey(key), isTrue, reason: '缺少序列 $key');
    }
  });

  test('笔段方向交替，顶底不连续同向', () {
    final r = Chanlun.analyze(bars, formula);
    for (var i = 1; i < r.pens.length; i++) {
      expect(r.pens[i].type, isNot(r.pens[i - 1].type), reason: '第 $i 个笔与前一个同向');
    }
    for (final seg in r.bi) {
      expect(seg.dir, anyOf('up', 'down'));
      expect(seg.len, greaterThan(0));
    }
  });

  test('背驰与买卖点能正常产出', () {
    final r = Chanlun.analyze(bars, formula);
    expect(r.signals, isNotEmpty);
    expect(r.points, isNotEmpty);
    for (final s in r.signals) {
      expect(s.type, anyOf('buy', 'sell'));
      // 背驰必须创新极值，力度必须在 (0,1]
      final v = double.parse(s.strength);
      expect(v, greaterThan(0));
      expect(v, lessThanOrEqualTo(1));
    }
  });

  test('窗口缩短会丢中枢，400 根以上才收敛（实测记录，防止误改取数长度）', () {
    // 实测 300274：200 根→1 个中枢，270→2，300→3，400/500/640 都是 4。
    // 窗口越短左侧历史越少，左侧中枢直接算不出来，而不是多造伪框。
    // 所以取数应当尽量给满（当前用 640 根），不要因为「看起来够用」就截短。
    final boxesAt = <int, int>{};
    for (final n in [270, 300, 400, 640]) {
      boxesAt[n] = Chanlun.analyze(bars.sublist(bars.length - n), formula).boxes.length;
    }
    expect(boxesAt[270], lessThan(boxesAt[640]!), reason: '270 根应明显少于全量的中枢数');
    expect(boxesAt[400], boxesAt[640]!, reason: '400 根起结果已收敛，与全量一致');
  });

  test('viewStart 只裁剪显示范围，不改变计算结果', () {
    final r = Chanlun.analyze(bars, formula, viewStart: 400);
    expect(r.pens.length, 38, reason: '笔应仍按全历史算');
    for (final b in r.boxes) {
      expect(b.e, greaterThanOrEqualTo(400));
    }
  });

  test('性能：640 根在 2 秒内完成', () {
    final sw = Stopwatch()..start();
    Chanlun.analyze(bars, formula);
    sw.stop();
    expect(sw.elapsedMilliseconds, lessThan(2000));
  });
}
