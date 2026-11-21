/// 当前 K 线图的上下文快照。
///
/// 目的：让 AI 能回答「我这根 K 线现在什么情况」「这个指标说明什么」，
/// 而不是根据用户的一句话去猜他看的是哪只股票、哪个周期、哪根 K 线。
///
/// **刻意不做的事**：不把 640 根 K 线、所有指标序列全部塞进去。
/// 每次请求带上这些会让 token 消耗翻十倍，而且模型也不需要——
/// 它需要的是「当前在看什么」+「这一根的具体数值」+「结构摘要」。
///
/// **一个重要的可信度区分**（`indicatorsRepaint` 与 `structureRepaints`）：
///  - MA / BOLL / MACD / KDJ / RSI 都是纯价格序列计算，**不会重绘**，历史值稳定
///  - 缠论结构走通达信公式，公式里有 `BACKSET` / `REFX`，**会重绘**
/// 这两类结论的可信度不同，必须让模型知道。
library;

import 'chanlun.dart';
import 'indicators.dart';
import 'minute.dart';
import 'numbers.dart';

/// 主图 / 副图指标在某一根 K 线上的值。
class IndicatorValues {
  IndicatorValues(this.values);

  /// 键形如 `MA5` / `BOLL_MID` / `MACD_DIF` / `KDJ_K` / `RSI14`。
  final Map<String, double?> values;

  Map<String, dynamic> toJson() => {for (final e in values.entries) e.key: r2(e.value)};

  String renderText() {
    if (values.isEmpty) return '（无）';
    final parts = <String>[];
    for (final e in values.entries) {
      if (e.value == null) continue;
      parts.add('${e.key}=${fmt2(e.value!)}');
    }
    return parts.isEmpty ? '（无有效值）' : parts.join(' ');
  }

  static String fmt2(double v) => v.toStringAsFixed(2);
}

/// 计算某一根 K 线上的指标值。
///
/// 指标在**全量** K 线上算再取索引，不是只喂可视窗口——
/// 窗口不足会让 MA60 这类长期指标失真。
IndicatorValues indicatorValuesAt(
  List<Bar> bars,
  int idx, {
  // ★ 参数名不能叫 ma / boll：会遮蔽同名的指标函数，导致 boll(bars) 被当成
  //   对 bool 的调用。这类遮蔽编译期就报错，但只有真跑一遍才看得到。
  required bool includeMa,
  required bool includeBoll,
  required List<String> subs,
}) {
  if (idx < 0 || idx >= bars.length) return IndicatorValues(const {});
  final out = <String, double?>{};

  if (includeMa) {
    final m = maSeries(bars, [5, 10, 20]);
    for (final e in m.entries) {
      out[e.key] = e.value[idx];
    }
  }

  if (includeBoll) {
    final b = boll(bars);
    out['BOLL_MID'] = b.mid[idx];
    out['BOLL_UP'] = b.up[idx];
    out['BOLL_LOW'] = b.low[idx];
  }

  for (final s in subs) {
    switch (s) {
      case 'VOL':
        final v = volMaSeries(bars, [5, 10]);
        for (final e in v.entries) {
          out[e.key] = e.value[idx];
        }
        out['VOL'] = bars[idx].v;
      case 'MACD':
        final m = macd(bars);
        out['MACD_DIF'] = m.dif[idx];
        out['MACD_DEA'] = m.dea[idx];
        out['MACD_BAR'] = m.bar[idx];
      case 'KDJ':
        final k = kdj(bars);
        out['KDJ_K'] = k.k[idx];
        out['KDJ_D'] = k.d[idx];
        out['KDJ_J'] = k.j[idx];
      case 'RSI':
        final r = rsi(bars);
        out['RSI14'] = r[idx];
    }
  }
  return IndicatorValues(out);
}

/// 图表上下文快照。
class ChartContext {
  ChartContext({
    required this.symbol,
    required this.name,
    required this.period,
    required this.source,
    required this.barCount,
    required this.lastDate,
    required this.lastBarIsToday,
    required this.visibleStart,
    required this.visibleCount,
    this.cursorIndex,
    this.cursorBar,
    this.cursorIndicators,
    this.mainIndicators = const [],
    this.subIndicators = const [],
    this.penCount = 0,
    this.boxCount = 0,
    this.signalCount = 0,
    this.pointCount = 0,
    this.chanBoxPosition,
    this.chanUnknownFunctions = const [],
    this.minuteInfo,
    this.warnings = const [],
  });

  final String symbol;
  final String name;
  final String period;

  /// `tencent` / `sina` / `eastmoney`
  final String source;
  final int barCount;
  final String lastDate;

  /// 最后一根 K 线的日期是否就是今天（说明这根可能还在形成中）
  final bool lastBarIsToday;
  final int visibleStart;
  final int visibleCount;

  /// 十字光标 / 选中那根的索引；null 表示没有选中
  final int? cursorIndex;
  final Bar? cursorBar;
  final IndicatorValues? cursorIndicators;

  final List<String> mainIndicators;
  final List<String> subIndicators;

  final int penCount;
  final int boxCount;
  final int signalCount;
  final int pointCount;
  final String? chanBoxPosition;

  /// 缠论公式里未实现的函数名。非空说明结构可能不完整。
  final List<String> chanUnknownFunctions;

  /// 分时的额外信息（当前日期、昨收、最新价）
  final MinuteSeries? minuteInfo;

  final List<String> warnings;

  /// 指标是否可能重绘。
  ///
  /// 本项目所有指标（MA/BOLL/MACD/KDJ/RSI）都是纯价格序列计算，**不重绘**。
  /// 写成一个指向常量而不是散落在各处，是为了以后有人加了带未来函数的指标时
  /// 有一个明确的落点去改。
  bool get indicatorsRepaint => false;

  /// 缠论结构是否可能重绘。
  ///
  /// 公式里有 `BACKSET` / `REFX` / `BARSNEXT`，中枢右边界会随后续 K 线变化。
  /// 所以「图上画出来的结构」不等于「当时就能确认的结构」。
  bool get structureRepaints => true;

  Map<String, dynamic> toJson() => {
    'symbol': symbol,
    'name': name,
    'period': period,
    'source': source,
    'bar_count': barCount,
    'last_date': lastDate,
    'last_bar_is_today': lastBarIsToday,
    'visible': {'start': visibleStart, 'count': visibleCount},
    'cursor': cursorIndex == null
        ? null
        : {
            'index': cursorIndex,
            'date': cursorBar?.t,
            'open': r2(cursorBar?.o),
            'high': r2(cursorBar?.h),
            'low': r2(cursorBar?.l),
            'close': r2(cursorBar?.c),
            'volume': r2(cursorBar?.v),
          },
    'indicators': {
      'main': mainIndicators,
      'sub': subIndicators,
      'at_cursor': cursorIndicators?.toJson(),
      'repaints': indicatorsRepaint,
    },
    if (penCount > 0 || boxCount > 0)
      'chan': {
        'pens': penCount,
        'boxes': boxCount,
        'signals': signalCount,
        'points': pointCount,
        'box_position': chanBoxPosition,
        'repaints': structureRepaints,
      },
    if (chanUnknownFunctions.isNotEmpty) 'chan_unknown_functions': chanUnknownFunctions,
    if (minuteInfo != null)
      'minute': {
        'date': minuteInfo!.date,
        'prev_close': r2(minuteInfo!.prevClose),
        'last': r2(minuteInfo!.lastPrice),
        'change_pct': r2(minuteInfo!.changePct),
        'points': minuteInfo!.points.length,
      },
    if (warnings.isNotEmpty) 'warnings': warnings,
  };

  /// 渲染成给模型读的中文文本。比 JSON 省 token，也更不容易被误读。
  String renderText() {
    final b = StringBuffer();
    final periodLabel = switch (period) {
      'day' => '日线',
      'week' => '周线',
      'month' => '月线',
      'm60' => '60 分钟',
      'm30' => '30 分钟',
      'm15' => '15 分钟',
      'm5' => '5 分钟',
      'minute' => '分时',
      _ => period,
    };
    b.writeln('【当前图表：$name $symbol · $periodLabel】');
    b.writeln(
      '数据源 $source，共 $barCount 根，最后一根 ${lastDate}'
      '${lastBarIsToday ? '（今天，可能还没收盘）' : ''}',
    );

    final m = minuteInfo;
    if (m != null) {
      b.writeln(
        '分时：昨收 ${fmt2(m.prevClose)}，最新 ${fmt2(m.lastPrice)}'
        '（${m.changePct >= 0 ? '+' : ''}${m.changePct.toStringAsFixed(2)}%），'
        '${m.points.length} 个点',
      );
    }

    b.writeln('可视范围：第 $visibleStart ~ ${visibleStart + visibleCount - 1} 根');

    final bar = cursorBar;
    if (bar != null) {
      b.writeln(
        '选中第 $cursorIndex 根（${bar.t}）：'
        '开 ${fmt2(bar.o)} 高 ${fmt2(bar.h)} 低 ${fmt2(bar.l)} 收 ${fmt2(bar.c)} '
        '量 ${bar.v.toStringAsFixed(0)}',
      );
      final ind = cursorIndicators;
      if (ind != null && ind.values.isNotEmpty) {
        b.writeln('该根指标：${ind.renderText()}');
      }
    } else {
      b.writeln('当前没有选中某根 K 线（十字光标未激活）');
    }

    if (mainIndicators.isNotEmpty || subIndicators.isNotEmpty) {
      b.writeln(
        '开启的指标：主图 ${mainIndicators.isEmpty ? '无' : mainIndicators.join('、')}；'
        '副图 ${subIndicators.isEmpty ? '无' : subIndicators.join('、')}',
      );
      // 带上参数：模型解释「MACD_DIF=-1.67」时要知道它是 12/26 的 EMA 差，
      // 否则容易按别的参数口径去解释。
      final keys = <String>[
        if (mainIndicators.any((x) => x.startsWith('MA'))) 'MA',
        if (mainIndicators.any((x) => x.contains('BOLL'))) 'BOLL',
        ...subIndicators,
        if (subIndicators.contains('成交量')) 'VOLMA',
      ];
      final params = indicatorParamLine(keys);
      if (params.isNotEmpty) b.writeln('指标参数：$params');
    }

    if (penCount > 0 || boxCount > 0) {
      b.writeln(
        '缠论结构：笔 $penCount、中枢 $boxCount、背驰 $signalCount、买卖点 $pointCount'
        // boxPosition 的值就是「中枢上方/中枢下方/中枢内」，模板里不要再加「中枢」
        '${chanBoxPosition == null ? '' : '，现价$chanBoxPosition'}',
      );
    }

    if (chanUnknownFunctions.isNotEmpty) {
      b.writeln(
        '⚠ 缠论公式有 ${chanUnknownFunctions.length} 个函数未实现：'
        '${chanUnknownFunctions.take(5).join('、')}，相关序列为空',
      );
    }

    b.writeln(
      '可信度：指标数值由历史价格直接算出，不会变；'
      '缠论结构会重绘（公式含 BACKSET 等未来函数），'
      '图上画出来的结构不等于当时就能确认的结构。',
    );

    for (final w in warnings) {
      b.writeln('⚠ $w');
    }
    return b.toString().trimRight();
  }

  static String fmt2(double v) => v.toStringAsFixed(2);
}
