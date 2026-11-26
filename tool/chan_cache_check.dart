// 本地自检：`dart run tool/chan_cache_check.dart`
// chan_cache 是纯 Dart（不 import Flutter），CI 里由 test/chan_cache_test.dart 做正式门禁。
// ignore_for_file: avoid_print, avoid_relative_lib_imports

import '../lib/stock/chan_cache.dart';
import '../lib/stock/chanlun.dart';

int _fail = 0;

void _check(bool ok, String what) {
  if (!ok) {
    _fail++;
    print('✗ $what');
  }
}

List<Bar> _bars(int n, {String last = '2026-11-26'}) => [
  for (var i = 0; i < n; i++)
    Bar(10.0 + i, 11.0 + i, 9.0 + i, 10.5 + i, v: 1000, t: i == n - 1 ? last : '2026-01-${(i % 28) + 1}'),
];

void main() {
  const formula = 'A:=MA(C,5);';

  clearChanCache();
  final bars = _bars(60);

  final a = analyzeShared(bars, formula, symbol: 'sz300274');
  final b = analyzeShared(bars, formula, symbol: 'sz300274');
  _check(identical(a, b), '同一批数据第二次应命中缓存（返回同一个对象）');
  _check(chanCacheSize == 1, '缓存条目应为 1，实际 $chanCacheSize');

  // 最后一根变了 = 新 K 线到了，必须重算
  final next = _bars(60, last: '2026-11-27');
  final c = analyzeShared(next, formula, symbol: 'sz300274');
  _check(!identical(a, c), '最后一根时间变了应重算');
  _check(chanCacheSize == 2, '缓存条目应为 2，实际 $chanCacheSize');

  // 公式变了也必须重算
  final d = analyzeShared(next, 'B:=MA(C,10);', symbol: 'sz300274');
  _check(!identical(c, d), '公式变了应重算');

  // 不同标的不能串
  final e = analyzeShared(next, formula, symbol: 'sh600519');
  _check(!identical(c, e), '不同 symbol 不能命中同一条');

  // 条数变了（面板 640 vs 工具 60）不能串
  final f = analyzeShared(_bars(80, last: '2026-11-27'), formula, symbol: 'sz300274');
  _check(!identical(c, f), '根数变了应重算');

  // 空数据不崩
  final empty = analyzeShared(const <Bar>[], formula, symbol: 'x');
  _check(empty.pens.isEmpty, '空数据应返回空结果');

  // 上限：塞 30 份不同的，缓存不该无限涨
  for (var i = 0; i < 30; i++) {
    analyzeShared(_bars(40 + i), formula, symbol: 'sym$i');
  }
  _check(chanCacheSize <= 20, '缓存应被裁剪到 <= 20，实际 $chanCacheSize');

  print(_fail == 0 ? '✓ 全部通过' : '✗ $_fail 条失败');
}
