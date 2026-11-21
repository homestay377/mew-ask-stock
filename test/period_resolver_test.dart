import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/stock/period_resolver.dart';

/// 周期解析回归。
///
/// 背景：工具描述原来写着「默认沿用面板周期」，代码却是 `args['period'] ?? 'day'`,
/// `panelPeriod()` 定义了但从没被调用过。用户看到的图和 AI 分析的周期因此对不上，
/// 而且很难察觉——AI 不会主动说「我看到的是日线，不是你的 60 分钟图」。
void main() {
  const analysis = ['day', 'week', 'month', 'm60', 'm30', 'm15'];
  const chart = ['day', 'week', 'month', 'm60', 'm30', 'm15', 'm5', 'minute'];

  test('面板是 60 分钟、用户没说周期 → 用面板周期', () {
    final r = resolvePeriod(explicit: null, panel: 'm60', allowed: analysis, toolLabel: 'analyze_chan');
    expect(r.value, 'm60');
    expect(r.error, isNull);
  });

  test('显式指定优先于面板', () {
    final r = resolvePeriod(explicit: 'week', panel: 'day', allowed: analysis, toolLabel: 'analyze_chan');
    expect(r.value, 'week');
  });

  test('都没有时回落 day', () {
    final r = resolvePeriod(explicit: null, panel: null, allowed: analysis, toolLabel: 'analyze_chan');
    expect(r.value, 'day');
  });

  test('面板停在分时，缠论分析必须报错而不是静默切日线', () {
    final r = resolvePeriod(explicit: null, panel: 'minute', allowed: analysis, toolLabel: 'analyze_chan');
    expect(r.isOk, isFalse);
    expect(r.error, contains('minute'));
    expect(r.error, contains('不支持'));
  });

  test('stock_kline 支持分时，不该报错', () {
    final r = resolvePeriod(explicit: null, panel: 'minute', allowed: chart, toolLabel: 'stock_kline');
    expect(r.value, 'minute');
  });

  test('模型传了不支持的周期 → 报错并列出可用值', () {
    final r = resolvePeriod(explicit: 'm5', panel: 'day', allowed: analysis, toolLabel: 'analyze_chan');
    expect(r.isOk, isFalse);
    expect(r.error, contains('m5'));
    expect(r.error, contains('day'));
  });

  test('显式指定覆盖不匹配的面板周期', () {
    final r = resolvePeriod(explicit: 'm15', panel: 'month', allowed: analysis, toolLabel: 'analyze_chan');
    expect(r.value, 'm15');
  });
}
