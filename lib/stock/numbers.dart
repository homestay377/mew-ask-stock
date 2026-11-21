/// 数字格式化与 JSON 安全转换。
///
/// 单独一个文件是因为**这两类问题在项目里反复出现**：
///
///  1. `jsonEncode(double.nan)` 会抛 `JsonUnsupportedObjectError`。
///     很多地方为了「保留两位小数」写成 `double.parse(x.toStringAsFixed(2))`，
///     x 是 NaN 时 `toStringAsFixed` 返回 "NaN"，`double.parse` 直接抛异常，
///     整个工具就失败了——而实际只是「数据不足」这种正常情况。
///
///  2. 接口偶尔给 "NaN" 字符串，`double.tryParse` 是会成功的，
///     一旦流进计算，NaN 会顺着加减乘除传染，最后整列指标全废。
library;

/// 保留两位小数，且保证结果可被 jsonEncode。
///
/// NaN / Infinity / null 一律返回 null，让 JSON 里是 `null` 而不是崩溃。
double? r2(double? v) {
  if (v == null || !v.isFinite) return null;
  // + 0.0 是为了把 -0.0 归一成 0.0，否则界面上会出现「-0.00」这种看着像负值的零
  return double.parse(v.toStringAsFixed(2)) + 0.0;
}

/// 数值比较的相等判断（NaN 算不相等）。
bool sameNum(double? a, double? b) {
  if (a == null || b == null) return a == b;
  if (!a.isFinite || !b.isFinite) return false;
  return (a - b).abs() < 1e-9;
}

/// 原子写文件的临时文件名序号。
///
/// 同一文件可能有并发写（面板后台刷新 + AI 画线保存），共用一个 `.tmp`
/// 会互相覆盖。用自增序号保证唯一，比时间戳可靠（同一微秒内可能重复）。
int _tmpSeq = 0;

/// 取一个进程内唯一的临时文件后缀。
int nextTmpSeq() => ++_tmpSeq;

/// 带并发上限的 map。
///
/// 批量扫描 20 只股票时，如果全部并发会一次打出 40 个请求，
/// 很容易触发接口限流甚至 WAF。限制在个位数既够快也不会被当成攻击。
Future<List<R>> mapLimit<T, R>(List<T> items, int limit, Future<R> Function(T) fn) {
  final results = List<R?>.filled(items.length, null);
  var next = 0;

  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= items.length) return;
      results[i] = await fn(items[i]);
    }
  }

  final workers = <Future<void>>[for (var i = 0; i < (limit < items.length ? limit : items.length); i++) worker()];
  return Future.wait(workers).then((_) => [for (final r in results) r as R]);
}
