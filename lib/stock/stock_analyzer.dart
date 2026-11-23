/// 把「取数 + 缠论 + 中文摘要」串成一条链，供 AI 工具直接调用。
///
/// 设计原则：**数据属于 App 自己**，不依赖任何界面状态。AI 要什么就现算，
/// 不需要先切面板、也不需要读屏幕。
library;

import 'chanlun.dart';
import 'data_quality.dart';
import 'numbers.dart';
import 'stock_fundamental.dart';
import 'stock_source.dart';

/// 单个标的的缠论分析结果（含渲染好的中文摘要）。
class StockAnalysis {
  StockAnalysis({required this.series, required this.chan, required this.summary, required this.elapsedMs});

  final KlineSeries series;
  final ChanResult chan;

  /// 给模型读的中文摘要，已包含所有关键数字。
  final String summary;
  final int elapsedMs;

  Map<String, dynamic> toJson() => {
    'symbol': series.symbol,
    'name': series.name,
    'period': series.period,
    'bars': series.length,
    // 数据来历与质量：模型引用结论前必须能看到这些，不能只给干净的数字
    'data': {
      'source': series.source,
      'adjust': series.adjust,
      if (series.fallbackReason != null) 'degraded_reason': series.fallbackReason,
      ...series.clock.toJson(),
      'from_cache': series.fromCache,
      'cache_age': series.cacheAge == null ? null : humanAge(series.cacheAge!),
      'quality': series.quality.toJson(),
    },
    'last': {
      'date': series.last.t,
      'open': series.last.o,
      'high': series.last.h,
      'low': series.last.l,
      'close': series.last.c,
      // 盘中这根还没收盘：价格会一直漂，不能当收盘价用，也不能当「现状」写进结论。
      'is_intraday': series.clock.closed == false,
    },
    'pens': chan.pens.length,
    'bars_used': series.bars.length,
    // 中枢、背驰、买卖点都带日期：只给索引，模型只能自己换算，还会猜错 ±1 个交易日。
    'boxes': [
      for (final b in chan.boxes)
        {
          'tag': b.tag,
          'start': b.s,
          'end': b.e,
          'start_date': _dateAt(series, b.s),
          'end_date': _dateAt(series, b.e),
          'zg': r2(b.zg),
          'zd': r2(b.zd),
        },
    ],
    'signals': [
      for (final s in chan.signals)
        {
          'idx': s.idx,
          'date': _dateAt(series, s.idx),
          'type': s.type,
          'label': s.label,
          'price': r2(s.price),
          'strength': s.strength,
          // 原始面积一起给：模型才能自己核「哪一段 vs 哪一段」，
          // 而不是只能说「面积是公式内部算的，无法复算」。
          if (s.fromIdx != null) 'from_idx': s.fromIdx,
          if (s.areaPrev != null) 'macd_area_prev': r2(s.areaPrev),
          if (s.areaCur != null) 'macd_area_cur': r2(s.areaCur),
        },
    ],
    'points': [
      for (final p in chan.points)
        {'idx': p.idx, 'date': _dateAt(series, p.idx), 'label': p.label, 'price': r2(p.price), 'reason': p.reason},
    ],
    // BACKSET 导致中枢右端会随新数据后延；显式告诉模型，别把它当成终稿。
    'repaints': true,
    'repaints_note': '中枢右端会随新 K 线后延（公式用了 BACKSET），图上看到的结构不等于当时就能确认的结构',
    'boxPosition': chan.stats.boxPosition,
    'formulaErrors': chan.errors.length,
    'elapsedMs': elapsedMs,
  };
}

class StockAnalyzer {
  StockAnalyzer({StockSource? source, required this.formula}) : source = source ?? StockSource();

  final StockSource source;

  /// 缠论公式原文（`assets/stock/chan_formula.txt`）。由调用方注入，方便测试。
  final String formula;

  /// 拉 K 线并跑缠论。
  ///
  /// [viewStart] 只裁剪显示范围，不影响计算。传 0 表示不裁剪。
  Future<StockAnalysis> analyze(
    String symbol, {
    String period = 'day',
    int count = chanBarCount,
    int viewStart = 0,
  }) async {
    final sw = Stopwatch()..start();
    final series = await source.kline(symbol, period: period, count: count);
    final chan = Chanlun.analyze(series.bars, formula, viewStart: viewStart, symbol: series.symbol, name: series.name);
    sw.stop();
    return StockAnalysis(
      series: series,
      chan: chan,
      summary: renderSummary(series, chan),
      elapsedMs: sw.elapsedMilliseconds,
    );
  }

  /// 渲染成中文摘要。数字保留两位小数，避免模型看到一长串浮点尾数。
  static String renderSummary(KlineSeries s, ChanResult r) {
    final b = StringBuffer();
    // 空列表直接返回说明，避免 s.last / s.first 抛 RangeError
    if (s.bars.isEmpty) return '【${s.name} ${s.symbol}】没有拿到 K 线数据。';
    final last = s.last;

    b.writeln('【${s.name} ${s.symbol} · ${periodName(s.period)}】');
    b.writeln(
      'K 线 ${s.length} 根（${displayBarTime(s.period, s.first.t)} 至 ${displayBarTime(s.period, last.t)}），'
      '最新 ${fmtNum(last.c)}，'
      '开 ${fmtNum(last.o)} 高 ${fmtNum(last.h)} 低 ${fmtNum(last.l)}',
    );

    // 数据来历写在结构前面：读者要先知道「这份数据可信到什么程度」
    b.writeln('数据：${s.provenance}');
    final q = s.quality;
    if (!q.ok) {
      b.writeln('⚠ 数据质量存疑，下面的结构判断要打折：');
      for (final issue in q.issues) {
        b.writeln('  · $issue');
      }
    }

    b.writeln('笔 ${r.pens.length} 个，中枢 ${r.boxes.length} 个');

    if (r.boxes.isNotEmpty) {
      b.writeln('中枢：');
      for (final box in r.boxes) {
        b.writeln(
          '  ${box.tag}[${box.s}-${box.e}] '
          'ZG=${fmtNum(box.zg)} ZD=${fmtNum(box.zd)}',
        );
      }
      final pos = r.stats.boxPosition;
      if (pos != null) b.writeln('现价位于最后一个中枢：$pos');
    }

    if (r.signals.isNotEmpty) {
      b.writeln('背驰信号 ${r.signals.length} 个：');
      for (final sig in r.signals) {
        b.writeln(
          '  ${sig.label} @${fmtNum(sig.price)} '
          '（索引 ${sig.idx}，力度衰减 ${sig.strength}）',
        );
      }
    } else {
      b.writeln('没有识别到背驰信号。');
    }

    if (r.points.isNotEmpty) {
      b.writeln('买卖点 ${r.points.length} 个：');
      for (final p in r.points) {
        b.writeln('  ${p.label} @${fmtNum(p.price)} —— ${p.reason}');
      }
    } else {
      b.writeln('没有识别到三类买卖点。');
    }

    if (r.unknownFunctions.isNotEmpty) {
      b.writeln(
        '⚠ 公式里有 ${r.unknownFunctions.length} 个函数本工具未实现，'
        '对应序列全是空值：${r.unknownFunctions.take(6).join('、')}'
        '${r.unknownFunctions.length > 6 ? ' 等' : ''}',
      );
      b.writeln('   这会直接影响依赖它们的判断，下结论前要说明这个限制。');
    }

    if (r.errors.isNotEmpty) {
      b.writeln('⚠ 公式解析有 ${r.errors.length} 条错误，结果可能不完整：');
      for (final e in r.errors.take(3)) {
        b.writeln('  第 ${e.line} 行：${e.message}');
      }
    }

    return b.toString().trimRight();
  }

  static String periodName(String p) => switch (p) {
    'day' => '日线',
    'week' => '周线',
    'month' => '月线',
    'm60' => '60 分钟',
    'm30' => '30 分钟',
    'm15' => '15 分钟',
    'm5' => '5 分钟',
    _ => p,
  };
}

/// 取第 [i] 根 K 线的日期；越界返回 null。
String? _dateAt(KlineSeries s, int i) {
  if (i < 0 || i >= s.bars.length) return null;
  final bar = s.bars[i];
  return bar.t.isEmpty ? null : bar.t;
}
