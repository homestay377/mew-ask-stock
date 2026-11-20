/// 分组涨跌统计。
///
/// 口径：把组内每只股票的涨跌幅取简单平均（等权）。
/// 停牌或取数失败的股票不参与平均——把它们算成 0 会把整组的平均值拉平，
/// 比直接少算一只更容易误导。
library;

/// 一只股票在分组统计里的输入。
class GroupMemberQuote {
  GroupMemberQuote({required this.code, required this.changePct});

  final String code;

  /// 涨跌幅（百分数，如 -1.23 表示跌 1.23%）。
  final double changePct;
}

/// 分组涨跌汇总。
class GroupStats {
  GroupStats({required this.count, required this.avgPct, required this.up, required this.down, required this.missing});

  /// 参与统计的股票数（不含取数失败的）。
  final int count;

  /// 平均涨跌幅；[count] 为 0 时为 null。
  final double? avgPct;

  /// 上涨 / 下跌只数。
  final int up;
  final int down;

  /// 取数失败或停牌的只数。
  final int missing;

  bool get hasData => count > 0;
}

/// 计算分组统计。[quotes] 里 null 表示该只取数失败。
GroupStats computeGroupStats(List<GroupMemberQuote?> quotes) {
  var count = 0;
  var missing = 0;
  var up = 0;
  var down = 0;
  var sum = 0.0;

  for (final q in quotes) {
    if (q == null) {
      missing++;
      continue;
    }
    if (!q.changePct.isFinite) {
      missing++;
      continue;
    }
    count++;
    sum += q.changePct;
    if (q.changePct > 0) {
      up++;
    } else if (q.changePct < 0) {
      down++;
    }
  }

  return GroupStats(count: count, avgPct: count == 0 ? null : sum / count, up: up, down: down, missing: missing);
}
