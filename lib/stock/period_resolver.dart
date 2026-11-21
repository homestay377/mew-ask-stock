/// 工具参数的周期解析。
///
/// **为什么单独一个文件**：之前的实现里，工具描述写着「默认沿用面板周期」，
/// 代码却是 `args['period'] ?? 'day'`——`panelPeriod()` 定义出来一次都没调用过。
/// 描述与实现不符，用户看到的图和 AI 分析的周期对不上，而且很难察觉。
///
/// 抽成纯函数后可以脱离 Flutter 直接测试，避免再出现「写了但没接线」。
library;

/// 解析结果。二选一：要么有周期，要么有错误说明。
class PeriodResolution {
  const PeriodResolution.ok(this.value) : error = null;
  const PeriodResolution.fail(this.error) : value = null;

  final String? value;
  final String? error;

  bool get isOk => value != null;
}

/// 解析该用哪个周期。
///
/// 优先级：**显式指定 > 面板当前周期 > 工具默认**。
///
/// 关键规则：显式指定或面板周期**不被该工具支持**时，返回错误而不是静默退回默认值。
/// 静默退回会让用户以为 AI 看的是他眼前的图，实际看的是日线——这比直接报错更坏。
///
/// - [explicit] 模型传的 period 参数
/// - [panel] 面板当前周期（`stockPanelRequest.currentPeriod`）
/// - [allowed] 该工具支持的周期
/// - [toolLabel] 工具名，用于拼错误信息
PeriodResolution resolvePeriod({
  Object? explicit,
  String? panel,
  required List<String> allowed,
  required String toolLabel,
}) {
  final raw = '${explicit ?? ''}'.trim();

  if (raw.isNotEmpty) {
    if (!allowed.contains(raw)) {
      return PeriodResolution.fail('$toolLabel 不支持周期「$raw」，可用：${allowed.join(' / ')}');
    }
    return PeriodResolution.ok(raw);
  }

  final p = (panel ?? '').trim();
  if (p.isNotEmpty) {
    if (!allowed.contains(p)) {
      return PeriodResolution.fail(
        '当前面板是「$p」，$toolLabel 不支持这个周期。'
        '请切到 ${allowed.join(' / ')} 之一，或直接指定 period。',
      );
    }
    return PeriodResolution.ok(p);
  }

  // 都没有：用该工具的第一个可用周期（各工具都把 day 放第一位）
  return PeriodResolution.ok(allowed.first);
}
