import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/stock/chanlun.dart';
import 'package:mewhub/stock/chart_context.dart';

/// 图表上下文回归。
///
/// 重点验证两件事：
///  1. `indicatorValuesAt` 取到的值和直接算的一致（否则 AI 引用的数值是错的）
///  2. 只给模型它需要的，不给它不需要的（token 成本）
void main() {
  final bars = <Bar>[
    for (var i = 0; i < 120; i++)
      Bar(10.0 + i * 0.1, 10.5 + i * 0.1, 9.5 + i * 0.1, 10.2 + i * 0.1, v: 1000 + i * 10, t: 'd$i'),
  ];

  test('MA 值与直接计算一致', () {
    final v = indicatorValuesAt(bars, bars.length - 1, includeMa: true, includeBoll: false, subs: const []);
    double direct(int n) {
      var sum = 0.0;
      for (var i = bars.length - n; i < bars.length; i++) {
        sum += bars[i].c;
      }
      return sum / n;
    }

    expect(v.values['MA5'], closeTo(direct(5), 1e-9));
    expect(v.values['MA10'], closeTo(direct(10), 1e-9));
    expect(v.values['MA20'], closeTo(direct(20), 1e-9));
  });

  test('指标在全量上算，不在可视窗口上算', () {
    // 取第 50 根，指针计算用的是 bars[0..50]，不是 bars[30..50]
    final v = indicatorValuesAt(bars, 50, includeMa: true, includeBoll: false, subs: const []);
    var sum = 0.0;
    for (var i = 31; i <= 50; i++) {
      sum += bars[i].c;
    }
    expect(v.values['MA20'], closeTo(sum / 20, 1e-9));
  });

  test('索引越界返回空，不抛异常', () {
    expect(indicatorValuesAt(bars, -1, includeMa: true, includeBoll: true, subs: const ['MACD']).values, isEmpty);
    expect(indicatorValuesAt(bars, 99999, includeMa: true, includeBoll: true, subs: const ['MACD']).values, isEmpty);
  });

  test('没开任何指标时不返回任何值（省 token）', () {
    final v = indicatorValuesAt(bars, 100, includeMa: false, includeBoll: false, subs: const []);
    expect(v.values, isEmpty);
    expect(v.renderText(), '（无）');
  });

  test('只开 MACD 时不含 MA / BOLL 的键', () {
    final v = indicatorValuesAt(bars, 100, includeMa: false, includeBoll: false, subs: const ['MACD']);
    expect(v.values.keys, containsAll(['MACD_DIF', 'MACD_DEA', 'MACD_BAR']));
    expect(v.values.keys.any((k) => k.startsWith('MA')), isFalse);
    expect(v.values.keys.any((k) => k.startsWith('BOLL')), isFalse);
  });

  test('上下文文本包含日期、周期、指标值和可信度说明', () {
    final ctx = ChartContext(
      symbol: 'sz300274',
      name: '阳光电源',
      period: 'day',
      source: 'tencent',
      barCount: bars.length,
      lastDate: '2026-11-20',
      lastBarIsToday: false,
      visibleStart: 0,
      visibleCount: 120,
      cursorIndex: 119,
      cursorBar: bars.last,
      cursorIndicators: indicatorValuesAt(bars, 119, includeMa: true, includeBoll: false, subs: const ['MACD']),
      mainIndicators: ['MA'],
      subIndicators: ['MACD'],
    );
    final text = ctx.renderText();

    expect(text, contains('日线'));
    expect(text, contains('2026-11-20'));
    expect(text, contains('MA5='));
    expect(text, contains('MACD_DIF='));
    // 必须告诉模型指标不重绘、缠论会重绘
    expect(text, contains('不会变'));
    expect(text, contains('重绘'));
  });

  test('没有选中 K 线时明确说明，不留空', () {
    final ctx = ChartContext(
      symbol: 'sz300274',
      name: '阳光电源',
      period: 'day',
      source: 'tencent',
      barCount: 100,
      lastDate: '2026-11-20',
      lastBarIsToday: false,
      visibleStart: 0,
      visibleCount: 100,
    );
    expect(ctx.renderText(), contains('没有选中'));
  });
}
