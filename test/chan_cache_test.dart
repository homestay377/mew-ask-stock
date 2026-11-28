import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/stock/chan_cache.dart';
import 'package:mewhub/stock/chanlun.dart';

/// 面板和 AI 工具共用一份缠论结果（见 lib/stock/chan_cache.dart）。
///
/// 这个缓存的关键不在「快」，而在于**两边拿到的一定是同一份**——
/// 否则图上画的中枢和模型说的中枢会不一致，而且没人能发现。
List<Bar> _bars(int n, {String last = '2026-11-26'}) => [
  for (var i = 0; i < n; i++)
    Bar(10.0 + i, 11.0 + i, 9.0 + i, 10.5 + i, v: 1000, t: i == n - 1 ? last : '2026-01-${(i % 28) + 1}'),
];

void main() {
  const formula = 'A:=MA(C,5);';

  setUp(clearChanCache);

  test('同一批数据第二次取到的是同一个对象', () {
    final bars = _bars(60);
    final a = analyzeShared(bars, formula, symbol: 'sz300274');
    final b = analyzeShared(bars, formula, symbol: 'sz300274');
    expect(identical(a, b), isTrue);
    expect(chanCacheSize, 1);
  });

  test('日线和周线不会互相命中——周期必须进键', () {
    // 同一批 bars、同一个 symbol、同一个最后一根日期，只有周期不同。
    // 实测事故：600036 的周线结论与日线逐位相同，就是这里漏了 period。
    final bars = _bars(60);
    final day = analyzeShared(bars, formula, period: 'day', symbol: 'sz300274');
    final week = analyzeShared(bars, formula, period: 'week', symbol: 'sz300274');
    expect(identical(day, week), isFalse);
  });

  test('新 K 线（最后一根时间变了）会失效重算', () {
    final a = analyzeShared(_bars(60), formula, symbol: 'sz300274');
    final b = analyzeShared(_bars(60, last: '2026-11-27'), formula, symbol: 'sz300274');
    expect(identical(a, b), isFalse);
  });

  test('公式变了会失效重算', () {
    final bars = _bars(60);
    final a = analyzeShared(bars, formula, symbol: 'x');
    final b = analyzeShared(bars, 'B:=MA(C,10);', symbol: 'x');
    expect(identical(a, b), isFalse);
  });

  test('不同标的、不同根数不会串', () {
    final bars = _bars(60);
    final a = analyzeShared(bars, formula, symbol: 'sz300274');
    expect(identical(a, analyzeShared(bars, formula, symbol: 'sh600519')), isFalse);
    expect(identical(a, analyzeShared(_bars(80), formula, symbol: 'sz300274')), isFalse);
  });

  test('空数据不崩，也不进缓存', () {
    final r = analyzeShared(const <Bar>[], formula, symbol: 'x');
    expect(r.pens, isEmpty);
    expect(chanCacheSize, 0);
  });

  test('缓存条目有上限', () {
    for (var i = 0; i < 30; i++) {
      analyzeShared(_bars(40 + i), formula, symbol: 'sym$i');
    }
    expect(chanCacheSize, lessThanOrEqualTo(20));
  });
}
