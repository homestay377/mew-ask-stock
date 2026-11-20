/// 把「取数 + 缠论 + 中文摘要」串成一条链，供 AI 工具直接调用。
///
/// 设计原则：**数据属于 App 自己**，不依赖任何界面状态。AI 要什么就现算，
/// 不需要先切面板、也不需要读屏幕。
library;

import 'chanlun.dart';
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
    'last': {
      'date': series.last.t,
      'open': series.last.o,
      'high': series.last.h,
      'low': series.last.l,
      'close': series.last.c,
    },
    'pens': chan.pens.length,
    'boxes': [
      for (final b in chan.boxes)
        {
          'tag': b.tag,
          'start': b.s,
          'end': b.e,
          'zg': double.parse(b.zg.toStringAsFixed(2)),
          'zd': double.parse(b.zd.toStringAsFixed(2)),
        },
    ],
    'signals': [
      for (final s in chan.signals)
        {
          'idx': s.idx,
          'type': s.type,
          'label': s.label,
          'price': double.parse(s.price.toStringAsFixed(2)),
          'strength': s.strength,
        },
    ],
    'points': [
      for (final p in chan.points)
        {'idx': p.idx, 'label': p.label, 'price': double.parse(p.price.toStringAsFixed(2)), 'reason': p.reason},
    ],
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
    final chan = Chanlun.analyze(series.bars, formula, viewStart: viewStart);
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
    final last = s.last;

    b.writeln('【${s.name} ${s.symbol} · ${periodName(s.period)}】');
    b.writeln(
      'K 线 ${s.length} 根（${s.first.t} 至 ${last.t}），'
      '最新 ${last.c.toStringAsFixed(2)}，'
      '开 ${last.o.toStringAsFixed(2)} 高 ${last.h.toStringAsFixed(2)} 低 ${last.l.toStringAsFixed(2)}',
    );

    b.writeln('笔 ${r.pens.length} 个，中枢 ${r.boxes.length} 个');

    if (r.boxes.isNotEmpty) {
      b.writeln('中枢：');
      for (final box in r.boxes) {
        b.writeln(
          '  ${box.tag}[${box.s}-${box.e}] '
          'ZG=${box.zg.toStringAsFixed(2)} ZD=${box.zd.toStringAsFixed(2)}',
        );
      }
      final pos = r.stats.boxPosition;
      if (pos != null) b.writeln('现价位于最后一个中枢：$pos');
    }

    if (r.signals.isNotEmpty) {
      b.writeln('背驰信号 ${r.signals.length} 个：');
      for (final sig in r.signals) {
        b.writeln(
          '  ${sig.label} @${sig.price.toStringAsFixed(2)} '
          '（索引 ${sig.idx}，力度衰减 ${sig.strength}）',
        );
      }
    } else {
      b.writeln('没有识别到背驰信号。');
    }

    if (r.points.isNotEmpty) {
      b.writeln('买卖点 ${r.points.length} 个：');
      for (final p in r.points) {
        b.writeln('  ${p.label} @${p.price.toStringAsFixed(2)} —— ${p.reason}');
      }
    } else {
      b.writeln('没有识别到三类买卖点。');
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
