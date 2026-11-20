/// 股票分析工具：把 `lib/stock/` 的能力暴露给模型。
///
/// 挂载点：`ChatController._collectTools()` 里 `...buildStockTools(...)`。
/// 与 MewHub 原有工具完全同构（`AppTool`），不需要碰工具循环本身。
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../stock/chart_shapes.dart';
import '../stock/shape_store.dart';
import '../stock/stock_analyzer.dart';
import '../stock/stock_source.dart';
import 'tool.dart';

/// 公式原文从 assets 读一次然后缓存。
String? _formulaCache;

Future<String> _formula() async {
  final cached = _formulaCache;
  if (cached != null) return cached;
  final text = await rootBundle.loadString('assets/stock/chan_formula.txt');
  _formulaCache = text;
  return text;
}

/// 构造股票工具集。
///
/// [enabled] 为 false 时返回空列表，方便在设置里一键关掉。
List<AppTool> buildStockTools({bool enabled = true}) {
  if (!enabled) return const [];

  // 整个会话共用一个数据源，复用 TCP 连接。
  // 与面板共用同一实例：切周期、AI 取数都能命中缓存。
  final source = sharedStockSource;

  Future<StockAnalyzer> analyzer() async => StockAnalyzer(source: source, formula: await _formula());

  return [
    AppTool(
      name: 'stock_kline',
      displayName: 'K线',
      description:
          '获取 A 股/指数的 K 线数据。返回最近若干根的开高低收量与均线、涨跌幅。'
          '用于确认价格位置、趋势方向和关键价位。代码可用 6 位数字（300274）或带前缀（sz300274）。',
      parameters: objectSchema(
        {
          'symbol': strProp('股票代码，如 300274 或 sh600519'),
          'period': strProp(
            '周期：day/week/month/m60/m30/m15/m5，默认 day',
            enumValues: ['day', 'week', 'month', 'm60', 'm30', 'm15', 'm5'],
          ),
          'count': intProp('取多少根，默认 60，最多 640'),
        },
        required: ['symbol'],
      ),
      promptHint: '取到 K 线后先看趋势方向和关键价位，再谈结论；不要凭一根 K 线下判断。',
      execute: (args) async {
        try {
          final symbol = '${args['symbol'] ?? ''}'.trim();
          if (symbol.isEmpty) return jsonEncode({'error': '缺少 symbol'});
          final period = '${args['period'] ?? 'day'}';
          final rawCount = args['count'];
          final count = rawCount is int ? rawCount.clamp(1, chanBarCount) : 60;

          final s = await source.kline(symbol, period: period, count: count);
          final bars = s.bars.length > 30 ? s.bars.sublist(s.bars.length - 30) : s.bars;

          final closes = s.bars.map((b) => b.c).toList();
          double maOf(int n) {
            if (closes.length < n) return double.nan;
            final seg = closes.sublist(closes.length - n);
            return seg.reduce((a, b) => a + b) / n;
          }

          return jsonEncode({
            'symbol': s.symbol,
            'name': s.name,
            'period': s.period,
            'total_bars': s.length,
            'first_date': s.first.t,
            'last_date': s.last.t,
            'ma5': maOf(5),
            'ma10': maOf(10),
            'ma20': maOf(20),
            'ma60': maOf(60),
            'bars': [
              for (final b in bars) {'t': b.t, 'o': b.o, 'h': b.h, 'l': b.l, 'c': b.c, 'v': b.v},
            ],
          });
        } catch (e) {
          return jsonEncode({'error': '$e'});
        }
      },
    ),

    AppTool(
      name: 'analyze_chan',
      displayName: '缠论',
      description:
          '对单个标的做缠论分析：笔、中枢、背驰、三类买卖点（一买/二买/三买/一卖/二卖/三卖）。'
          '返回可直接引用的中文结论与全部关键数字。这是分析走势结构的首选工具。',
      parameters: objectSchema(
        {
          'symbol': strProp('股票代码，如 300274'),
          'period': strProp(
            '周期：day/week/month/m60/m30/m15，默认 day',
            enumValues: ['day', 'week', 'month', 'm60', 'm30', 'm15'],
          ),
        },
        required: ['symbol'],
      ),
      promptHint:
          '缠论结论要给依据：中枢区间、背驰力度、买卖点位置。买卖点不是买卖建议，'
          '要说清它成立的条件和失效的价位。',
      execute: (args) async {
        try {
          final symbol = '${args['symbol'] ?? ''}'.trim();
          if (symbol.isEmpty) return jsonEncode({'error': '缺少 symbol'});
          final period = '${args['period'] ?? 'day'}';
          final az = await analyzer();
          final r = await az.analyze(symbol, period: period);
          return jsonEncode({'summary': r.summary, 'detail': r.toJson()});
        } catch (e) {
          return jsonEncode({'error': '$e'});
        }
      },
    ),

    AppTool(
      name: 'stock_quote',
      displayName: '实时行情',
      description: '获取实时价格、涨跌幅、开高低、成交量。用于确认当前价位，回答「现在多少钱」这类问题。',
      parameters: objectSchema({'symbol': strProp('股票代码，如 300274')}, required: ['symbol']),
      execute: (args) async {
        try {
          final symbol = '${args['symbol'] ?? ''}'.trim();
          if (symbol.isEmpty) return jsonEncode({'error': '缺少 symbol'});
          final q = await source.quote(symbol);
          return jsonEncode({
            'symbol': q.symbol,
            'name': q.name,
            'price': q.price,
            'prev_close': q.prevClose,
            'change': double.parse(q.change.toStringAsFixed(2)),
            'change_pct': double.parse(q.changePct.toStringAsFixed(2)),
            'open': q.open,
            'high': q.high,
            'low': q.low,
            'volume': q.volume,
            'amount': q.amount,
            'time': q.time,
          });
        } catch (e) {
          return jsonEncode({'error': '$e'});
        }
      },
    ),

    AppTool(
      name: 'stock_levels',
      displayName: '多级别',
      description:
          '一次拉多个周期的缠论结构做对照（周线/日线/60分/30分/15分）。'
          '判断「大级别方向 + 小级别买点」时必须用这个，不要自己切周期逐个问。',
      parameters: objectSchema(
        {'symbol': strProp('股票代码，如 300274'), 'periods': strProp('要对照的周期，逗号分隔，如 week,day,m60；默认 week,day,m60,m30,m15')},
        required: ['symbol'],
      ),
      promptHint: '多级别要说明各级别方向是否一致；不一致时指出冲突在哪一级别，以及以哪一级别为准。',
      execute: (args) async {
        try {
          final symbol = '${args['symbol'] ?? ''}'.trim();
          if (symbol.isEmpty) return jsonEncode({'error': '缺少 symbol'});
          final rawPeriods = '${args['periods'] ?? 'week,day,m60,m30,m15'}';
          final periods = rawPeriods.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

          final az = await analyzer();
          final out = <Map<String, dynamic>>[];
          for (final p in periods) {
            try {
              final r = await az.analyze(symbol, period: p, count: 400);
              out.add({
                'period': StockAnalyzer.periodName(p),
                'bars': r.series.length,
                'close': r.series.last.c,
                'pens': r.chan.pens.length,
                'boxes': r.chan.boxes.length,
                'box_position': r.chan.stats.boxPosition,
                'last_signals': [
                  for (final s in r.chan.signals.take(2))
                    {'label': s.label, 'price': double.parse(s.price.toStringAsFixed(2)), 'strength': s.strength},
                ],
                'last_points': [
                  for (final pt in r.chan.points.take(2))
                    {'label': pt.label, 'price': double.parse(pt.price.toStringAsFixed(2))},
                ],
              });
            } catch (e) {
              out.add({'period': p, 'error': '$e'});
            }
          }
          return jsonEncode({'symbol': symbol, 'levels': out});
        } catch (e) {
          return jsonEncode({'error': '$e'});
        }
      },
    ),
    AppTool(
      name: 'chart_annotate',
      displayName: '标注',
      description:
          '在 K 线图上画标注：水平线（支撑/压力/止损价）、趋势线、矩形区间、文字、箭头。'
          '当你要给出具体价位（支撑位、压力位、止损价、目标价）时用它画出来，'
          '比只在文字里报数字清楚得多。多次调用会累加。',
      parameters: objectSchema(
        {
          'symbol': strProp('股票代码，如 300274'),
          'period': strProp('周期：day/week/month/m60/m30/m15，默认 day'),
          'shapes': {
            'type': 'array',
            'description': '要画的图元列表',
            'items': {
              'type': 'object',
              'properties': {
                'kind': strProp('类型', enumValues: ['hline', 'trendline', 'rect', 'text', 'arrow', 'dot']),
                'index': intProp('起始 K 线索引（0=最早，-1=最新）'),
                'price': {'type': 'number', 'description': '起始价格'},
                'index2': intProp('终点 K 线索引（两点图元用）'),
                'price2': {'type': 'number', 'description': '终点价格（两点图元用）'},
                'text': strProp('文字内容（text 类型必填）'),
                'color': strProp('颜色含义', enumValues: ['up', 'down', 'resist', 'support', 'stop', 'target', 'accent']),
              },
              'required': ['kind'],
            },
          },
        },
        required: ['symbol', 'shapes'],
      ),
      promptHint: '画完要说明每条线代表什么价位、为什么在这个位置，不要只报坐标。',
      execute: (args) async {
        try {
          final symbol = '${args['symbol'] ?? ''}'.trim();
          if (symbol.isEmpty) return jsonEncode({'error': '缺少 symbol'});
          final period = '${args['period'] ?? 'day'}';
          final raw = args['shapes'];
          if (raw is! List || raw.isEmpty) return jsonEncode({'error': 'shapes 不能为空'});

          // 用真实 K 线确定有效索引范围，越界的坐标直接拒绝（避免画出乱线）
          final series = await source.kline(symbol, period: period);
          final total = series.bars.length;
          final existing = await ShapeStore.instance.load(series.symbol, period);

          int resolveIndex(Object? v, int fallback) {
            if (v is! num) return fallback;
            final i = v.toInt();
            if (i < 0) return (total + i).clamp(0, total - 1);
            return i.clamp(0, total - 1);
          }

          final added = <ChartShape>[];
          final rejected = <String>[];
          for (final item in raw) {
            if (item is! Map) continue;
            final kindName = '${item['kind'] ?? ''}';
            final kind = shapeKindFromName(kindName);
            if (kind == null) {
              rejected.add('未知类型 $kindName');
              continue;
            }
            final price = (item['price'] as num?)?.toDouble();
            if (price == null) {
              rejected.add('$kindName 缺少 price');
              continue;
            }
            final idx = resolveIndex(item['index'], total - 1);
            final needTwo =
                kind == ShapeKind.trendline ||
                kind == ShapeKind.rect ||
                kind == ShapeKind.arrow ||
                kind == ShapeKind.ray;
            if (needTwo && (item['index2'] == null || item['price2'] == null)) {
              rejected.add('$kindName 需要 index2 和 price2');
              continue;
            }
            added.add(
              ChartShape(
                kind: kind,
                i1: idx,
                p1: price,
                i2: needTwo ? resolveIndex(item['index2'], idx) : null,
                p2: needTwo ? (item['price2'] as num).toDouble() : null,
                text: item['text']?.toString(),
                color: shapeColorFromName('${item['color'] ?? 'accent'}'),
              ),
            );
          }

          if (added.isEmpty) {
            return jsonEncode({'error': '没有可画的图元', 'rejected': rejected});
          }

          final next = [...existing, ...added];
          await ShapeStore.instance.save(series.symbol, period, next);

          return jsonEncode({
            'ok': true,
            'symbol': series.symbol,
            'name': series.name,
            'period': period,
            'bars': total,
            'added': added.length,
            'total_shapes': next.length,
            if (rejected.isNotEmpty) 'rejected': rejected,
            'note': '已画到图上，用户切到该股该周期即可看到',
          });
        } catch (e) {
          return jsonEncode({'error': '$e'});
        }
      },
    ),
  ];
}
