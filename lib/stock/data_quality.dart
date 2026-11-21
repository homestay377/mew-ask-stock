/// 行情数据的「元数据与质量」层。
///
/// 目的不是校验得完美无缺，而是让分析结果能被追溯：
///  - 这批 K 线是哪个源给的、什么复权口径（`KlineSeries.source` / `adjust`）
///  - 最后一根是几号的、收了没有（[barClock]）
///  - 数据本身有没有明显毛病（[assessBars]）
///  - 这份数据是缓存还是刚拉的（`KlineSeries.fromCache` / `cacheAge`）
///
/// 只做只读检查，不改动 bars，也不发任何网络请求——纯函数，测试直接跑。
library;

import 'chanlun.dart';

/// 数据质量体检结果。所有计数都是「根数」，不是比例。
class KlineQuality {
  const KlineQuality({
    this.duplicateDates = 0,
    this.outOfOrder = 0,
    this.gaps = 0,
    this.badOhlc = 0,
    this.badVolume = 0,
    this.zeroVolume = 0,
    this.issues = const [],
  });

  /// 日期与前一根完全相同的根数。
  final int duplicateDates;

  /// 日期比前一根早的根数（倒序）。
  final int outOfOrder;

  /// 相邻两根之间间隔异常大的次数（日线 > 14 天、周线 > 21 天、月线 > 60 天）。
  /// 分钟线不检查——分钟线本来就跨交易日。
  final int gaps;

  /// OHLC 不自洽的根数：high < max(open, close)、low > min(open, close)、
  /// high < low、出现 0 或负数、出现 NaN/Infinity。
  final int badOhlc;

  /// 成交量为负或非有限值的根数。
  final int badVolume;

  /// 成交量为 0 的根数。停牌或极冷门标的会出现，**不算错误**，只上报。
  final int zeroVolume;

  /// 人话版问题清单，直接进摘要。空列表 = 没发现明显问题。
  final List<String> issues;

  bool get ok => issues.isEmpty;

  Map<String, dynamic> toJson() => {
    'ok': ok,
    'duplicate_dates': duplicateDates,
    'out_of_order': outOfOrder,
    'gaps': gaps,
    'bad_ohlc': badOhlc,
    'bad_volume': badVolume,
    'zero_volume': zeroVolume,
    'issues': issues,
  };
}

/// 解析 K 线时间字符串。
///
/// 实测各家格式：
///  - 腾讯日/周/月：`2026-11-20`
///  - 腾讯分钟：`202611201400`（**12 位，且是这根 K 线的结束时间**）
///  - 新浪：`2026-11-20` 或 `2026-11-20 15:00:00`
///  - 东财：`2026-11-20` 或 `2026-11-20 15:00`
///
/// 返回的是「北京时间墙上时钟」的朴素 DateTime，用来和 [nowCst] 对比。
/// 解析不出来返回 null——不猜。
DateTime? parseBarTime(String t) {
  final s = t.trim();
  if (s.isEmpty) return null;

  // 12 位纯数字：yyyyMMddHHmm
  if (s.length == 12 && int.tryParse(s) != null) {
    final y = int.parse(s.substring(0, 4));
    final mo = int.parse(s.substring(4, 6));
    final d = int.parse(s.substring(6, 8));
    final h = int.parse(s.substring(8, 10));
    final mi = int.parse(s.substring(10, 12));
    if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59) return null;
    return DateTime(y, mo, d, h, mi);
  }

  // 8 位纯数字：yyyyMMdd
  if (s.length == 8 && int.tryParse(s) != null) {
    final y = int.parse(s.substring(0, 4));
    final mo = int.parse(s.substring(4, 6));
    final d = int.parse(s.substring(6, 8));
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    return DateTime(y, mo, d);
  }

  // 带横线的日期，可选时间部分
  final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?').firstMatch(s);
  if (m == null) return null;
  final y = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  final d = int.parse(m.group(3)!);
  final h = m.group(4) == null ? 0 : int.parse(m.group(4)!);
  final mi = m.group(5) == null ? 0 : int.parse(m.group(5)!);
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59) return null;
  return DateTime(y, mo, d, h, mi);
}

/// 当前北京时间（朴素，不带时区标记），只和 [parseBarTime] 的结果比大小。
DateTime nowCst() {
  final u = DateTime.now().toUtc().add(const Duration(hours: 8));
  return DateTime(u.year, u.month, u.day, u.hour, u.minute, u.second);
}

/// 分钟周期对应的分钟数；日/周/月返回 null。
int? minutesOfPeriod(String period) => switch (period) {
  'm60' => 60,
  'm30' => 30,
  'm15' => 15,
  'm5' => 5,
  _ => null,
};

/// 体检一批 K 线。
///
/// [bars] 按时间正序排列（数据层就是这么给的）。只统计明显毛病，
/// 阈值宁可宽松也不要刷屏——假警报会让模型学会忽略警告。
KlineQuality assessBars(List<Bar> bars, String period) {
  if (bars.isEmpty) {
    return const KlineQuality(issues: ['没有 K 线数据']);
  }

  var duplicate = 0;
  var outOfOrder = 0;
  var gaps = 0;
  var badOhlc = 0;
  var badVolume = 0;
  var zeroVolume = 0;

  final gapThresholdDays = switch (period) {
    'day' => 14,
    'week' => 21,
    'month' => 60,
    _ => 0, // 分钟线不查跳空
  };

  final times = <DateTime?>[];
  for (var i = 0; i < bars.length; i++) {
    final b = bars[i];
    final t = parseBarTime(b.t);
    times.add(t);

    // OHLC 自洽：任何一项非有限或非正都算坏
    final finite = b.o.isFinite && b.h.isFinite && b.l.isFinite && b.c.isFinite && b.v.isFinite;
    if (!finite || b.o <= 0 || b.h <= 0 || b.l <= 0 || b.c <= 0) {
      badOhlc++;
    } else if (b.h < b.l || b.h < b.o - 1e-9 || b.h < b.c - 1e-9 || b.l > b.o + 1e-9 || b.l > b.c + 1e-9) {
      badOhlc++;
    }

    if (!b.v.isFinite || b.v < 0) {
      badVolume++;
    } else if (b.v == 0) {
      zeroVolume++;
    }

    if (i == 0) continue;

    // 日期完全相同的字符串 = 重复；解析后倒退 = 倒序
    if (bars[i].t == bars[i - 1].t) {
      duplicate++;
      continue;
    }
    final prev = times[i - 1];
    if (t != null && prev != null) {
      if (t.isBefore(prev)) outOfOrder++;
      if (gapThresholdDays > 0) {
        final days = t.difference(prev).inDays;
        if (days > gapThresholdDays) gaps++;
      }
    }
  }

  final issues = <String>[];
  if (duplicate > 0) issues.add('有 $duplicate 根 K 线日期重复，指标与缠论口径可能被重复值带偏');
  if (outOfOrder > 0) issues.add('有 $outOfOrder 处日期倒序，序列不是单调递增');
  if (gaps > 0) issues.add('有 $gaps 处时间跳空超过阈值，可能缺交易日（停牌或数据缺失）');
  if (badOhlc > 0) issues.add('有 $badOhlc 根 OHLC 不自洽（高低价与开收盘矛盾或非正数）');
  if (badVolume > 0) issues.add('有 $badVolume 根成交量为负或无效');
  if (bars.length < 30) issues.add('只有 ${bars.length} 根 K 线，样本过少，结构判断不可靠');

  return KlineQuality(
    duplicateDates: duplicate,
    outOfOrder: outOfOrder,
    gaps: gaps,
    badOhlc: badOhlc,
    badVolume: badVolume,
    zeroVolume: zeroVolume,
    issues: issues,
  );
}

/// 最后一根 K 线的「时间状态」：它是哪天/哪一刻的，收完没有，离现在多久。
///
/// [closed] 为 null 表示**判不出来**：时间字符串解析失败，或者数据源给的
/// 时间戳语义不明。这时不要假设它已收盘，也不要假设它是实时的。
class BarClock {
  const BarClock({
    required this.lastBar,
    required this.barTime,
    required this.closed,
    required this.age,
    required this.note,
  });

  final String lastBar;
  final DateTime? barTime;
  final bool? closed;
  final Duration? age;
  final String note;

  Map<String, dynamic> toJson() => {
    'last_bar': lastBar,
    'last_bar_time': barTime == null ? null : fmtDateTime(barTime!),
    'closed': closed,
    'age': age == null ? null : humanAge(age!),
    'note': note,
  };
}

String _p2(int v) => v < 10 ? '0$v' : '$v';

/// `2026-11-20` / `2026-11-20 15:00` 这种给人看的时间。
String fmtDateTime(DateTime d) => '${d.year}-${_p2(d.month)}-${_p2(d.day)} ${_p2(d.hour)}:${_p2(d.minute)}';

/// 判断最后一根 K 线的状态。
///
/// 口径：
///  - 日/周/月：收盘时间是当天 15:00。最后一根的时间点已经过了 15:00 就算收完。
///    没有交易日历，所以不区分节假日——宁可说「已收盘」也不假装实时。
///  - 分钟线：腾讯给的分钟时间戳是**这根 K 线的结束时刻**（10:30 = 9:30–10:30），
///    所以结束时刻 <= 现在就已收完。
BarClock barClock(String period, String lastBar) {
  final t = parseBarTime(lastBar);
  if (t == null) {
    return BarClock(lastBar: lastBar, barTime: null, closed: null, age: null, note: '时间格式无法解析，收盘状态未知');
  }

  final now = nowCst();
  final minutes = minutesOfPeriod(period);
  final DateTime endAt;
  bool? closed;

  if (minutes == null) {
    // 日/周/月：以当日 15:00 为收盘
    endAt = DateTime(t.year, t.month, t.day, 15, 0);
    closed = !now.isBefore(endAt);
  } else {
    endAt = t; // 分钟线时间戳本身就是结束时刻
    closed = !now.isBefore(endAt);
  }

  final age = now.isAfter(endAt) ? now.difference(endAt) : null;

  String note;
  if (closed == false) {
    note = '最后一根还没走完（${fmtDateTime(endAt)} 才收），它的高开低收随时会变';
  } else {
    final staleDays = now.difference(endAt).inDays;
    if (staleDays >= 4) {
      note = '最后一根是 ${fmtDateTime(endAt)} 的，已经 $staleDays 天没有更新，可能停牌或数据源滞后';
    } else {
      note = '最后一根已收盘（${fmtDateTime(endAt)}）';
    }
  }

  // 上报的是「这根 K 线的收线时刻」而不是原始时间戳：
  // 日线原始值是 00:00，直接给人看会被误读成「凌晨更新的」。
  return BarClock(lastBar: lastBar, barTime: endAt, closed: closed, age: age, note: note);
}

/// 「35 分钟前」这种给人看的时间差。
String humanAge(Duration d) {
  final s = d.inSeconds;
  if (s < 0) return '未来';
  if (s < 60) return '$s 秒前';
  if (s < 3600) return '${d.inMinutes} 分钟前';
  if (s < 86400) return '${d.inHours} 小时前';
  return '${d.inDays} 天前';
}

/// 把原始时间戳转成给人看的写法：日/周/月只到日，分钟到分钟。
///
/// 腾讯分钟线的原始值是 `202611201500`，直接塞进摘要里没法读，
/// 模型也容易把它当成数字而不是时间。解析不出来就原样返回，不编造。
String displayBarTime(String period, String t) {
  final d = parseBarTime(t);
  if (d == null) return t;
  final date = '${d.year}-${_p2(d.month)}-${_p2(d.day)}';
  return minutesOfPeriod(period) == null ? date : fmtDateTime(d);
}
