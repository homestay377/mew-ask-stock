/// 股票分析工具：把 `lib/stock/` 的能力暴露给模型。
///
/// 挂载点：`ChatController._collectTools()` 里 `...buildStockTools(...)`。
/// 与 MewHub 原有工具完全同构（`AppTool`），不需要碰工具循环本身。
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../stock/chart_shapes.dart';
import '../stock/stock_bridge.dart';
import '../stock/shape_store.dart';
import '../stock/stock_analyzer.dart';
import '../stock/numbers.dart';
import '../stock/period_resolver.dart';
import '../stock/stock_fundamental.dart';
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

/// 宽容的数字解析：接受数字、数字字符串，拒绝 NaN / 无穷。
double? _num(Object? v) {
  if (v == null) return null;
  final d = v is num ? v.toDouble() : double.tryParse(v.toString());
  if (d == null || !d.isFinite) return null;
  return d;
}

/// 各工具支持的周期。顺序里 day 放第一位，作为最终兜底。
const kChartPeriods = ['day', 'week', 'month', 'm60', 'm30', 'm15', 'm5', 'minute'];
const kAnalysisPeriods = ['day', 'week', 'month', 'm60', 'm30', 'm15'];

/// 解析工具要分析哪只股票。
///
/// **不传就用面板当前的标的**——用户说「分析一下」时，指的就是他正在看的那只。
/// 这比让模型追问一句「你说哪只」自然得多。
String? resolveSymbol(Object? raw) {
  final s = '${raw ?? ''}'.trim();
  if (s.isNotEmpty) return s;
  final cur = stockPanelRequest.currentSymbol;
  return (cur == null || cur.isEmpty) ? null : cur;
}

/// 面板当前的周期，作为不传 period 时的默认值。
String? panelPeriod() {
  final p = stockPanelRequest.currentPeriod;
  return (p == null || p.isEmpty) ? null : p;
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
      parameters: objectSchema({
        'symbol': strProp('股票代码，如 300274 / sh510300 / sh000001。不传则分析面板当前标的'),
        'period': strProp(
          '周期：day/week/month/m60/m30/m15/m5/minute（分时）。不传则沿用面板当前周期',
          enumValues: ['day', 'week', 'month', 'm60', 'm30', 'm15', 'm5', 'minute'],
        ),
        'count': intProp('取多少根，默认 60，最多 640'),
      }),
      promptHint: '取到 K 线后先看趋势方向和关键价位，再谈结论；不要凭一根 K 线下判断。',
      execute: (args) async {
        try {
          final symbol = resolveSymbol(args['symbol']);
          if (symbol == null) return jsonEncode({'error': '缺少 symbol，且面板没有正在看的股票'});
          final pr = resolvePeriod(
            explicit: args['period'],
            panel: panelPeriod(),
            allowed: kChartPeriods,
            toolLabel: 'stock_kline',
          );
          if (!pr.isOk) return jsonEncode({'error': pr.error});
          final period = pr.value!;

          // 分时：结构完全不同（按时间等分，没有 OHLC），单独处理。
          // 241 个点全返回会吃掉大量 token，所以只给摘要 + 每 15 分钟采样。
          if (period == 'minute') {
            final m = await source.minuteCached(symbol);
            final prices = [for (final p in m.points) p.price];
            final hi = prices.reduce((a, b) => a > b ? a : b);
            final lo = prices.reduce((a, b) => a < b ? a : b);
            final above = m.points.where((p) => p.price >= m.prevClose).length;
            final sampled = <List<Object>>[];
            for (var i = 0; i < m.points.length; i += 15) {
              sampled.add([m.points[i].label, r2(m.points[i].price) ?? 0]);
            }
            // 收盘那一点单独补上，采样可能刚好错过
            final lastLabel = m.points.last.label;
            if (sampled.isEmpty || sampled.last[0] != lastLabel) {
              sampled.add([lastLabel, r2(m.lastPrice) ?? 0]);
            }
            return jsonEncode({
              'symbol': m.symbol,
              'name': m.name,
              'period': 'minute',
              'date': m.date,
              'prev_close': r2(m.prevClose),
              'open': r2(prices.first),
              'high': r2(hi),
              'low': r2(lo),
              'last': r2(m.lastPrice),
              'change_pct': r2(m.changePct),
              'points': m.points.length,
              // 高于昨收的时间占比：粗看多空强弱，比逐点读省很多 token
              'above_prev_ratio': r2(m.points.isEmpty ? null : above / m.points.length),
              'sampled': sampled,
              'note': '分时没有 OHLC，缠论不适用于分时；量能请用日线或分钟线看',
            });
          }

          final rawCount = args['count'];
          final count = rawCount is int ? rawCount.clamp(1, chanBarCount) : 60;

          final s = await source.kline(symbol, period: period, count: count);
          final bars = s.bars.length > 30 ? s.bars.sublist(s.bars.length - 30) : s.bars;

          final closes = s.bars.map((b) => b.c).toList();
          double? maOf(int n) {
            // 数据不足返回 null：NaN 会让 jsonEncode 抛异常，整个工具挂掉
            if (closes.length < n) return null;
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
            'ma5': r2(maOf(5)),
            'ma10': r2(maOf(10)),
            'ma20': r2(maOf(20)),
            'ma60': r2(maOf(60)),
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
      parameters: objectSchema({
        'symbol': strProp('股票代码。不传则分析面板当前标的'),
        'period': strProp(
          '周期：day/week/month/m60/m30/m15，默认沿用面板周期',
          enumValues: ['day', 'week', 'month', 'm60', 'm30', 'm15'],
        ),
      }),
      promptHint:
          '缠论结论要给依据：中枢区间、背驰力度、买卖点位置。买卖点不是买卖建议，'
          '要说清它成立的条件和失效的价位。',
      execute: (args) async {
        try {
          final symbol = resolveSymbol(args['symbol']);
          if (symbol == null) return jsonEncode({'error': '缺少 symbol，且面板没有正在看的股票'});
          final pr = resolvePeriod(
            explicit: args['period'],
            panel: panelPeriod(),
            allowed: kAnalysisPeriods,
            toolLabel: 'analyze_chan',
          );
          // 面板停在分时 / m5 时明确告知，而不是偷偷切成日线
          if (!pr.isOk) return jsonEncode({'error': pr.error});
          final period = pr.value!;
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
      parameters: objectSchema({'symbol': strProp('股票代码。不传则取面板当前标的')}),
      execute: (args) async {
        try {
          final symbol = resolveSymbol(args['symbol']);
          if (symbol == null) return jsonEncode({'error': '缺少 symbol，且面板没有正在看的股票'});
          final q = await source.quote(symbol);
          return jsonEncode({
            'symbol': q.symbol,
            'name': q.name,
            'price': q.price,
            'prev_close': q.prevClose,
            'change': r2(q.change),
            'change_pct': r2(q.changePct),
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
          '一次分析多个周期（周/日/60分/30分/15分）的缠论结构，也可以一次传多只股票。'
          '判断「大级别方向 + 小级别买点」、或横向对比几只股票时用它，'
          '不要自己切周期或逐个问——那样会多花好几倍轮次。\n'
          'symbols 支持多只（逗号分隔），内部并行取数。',
      parameters: objectSchema(
        {
          'symbols': strProp('股票代码，多只用逗号分隔，如 300274,600519,000001'),
          'periods': strProp('要对照的周期，逗号分隔，默认 week,day,m60,m30,m15'),
          'bars': intProp('每个周期取多少根，默认 400（缠论建议 >=400）'),
        },
        required: ['symbols'],
      ),
      promptHint:
          '多级别要说明各级别方向是否一致；不一致时指出冲突在哪一级别、以哪一级别为准。'
          '多只股票对比要给出横向排序依据，而不是逐只念一遍。',
      execute: (args) async {
        try {
          final rawSymbols = '${args['symbols'] ?? args['symbol'] ?? ''}'.trim();
          if (rawSymbols.isEmpty) return jsonEncode({'error': '缺少 symbols'});

          final symbols = rawSymbols.split(RegExp(r'[,，\s]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
          if (symbols.isEmpty) return jsonEncode({'error': 'symbols 解析后为空'});

          // 批量上限：再多会被接口限流，也超出模型一次能消化的量
          const maxSymbols = 8;
          final truncated = symbols.length > maxSymbols;
          final list = truncated ? symbols.take(maxSymbols).toList() : symbols;

          final rawPeriods = '${args['periods'] ?? 'week,day,m60,m30,m15'}';
          final periods = rawPeriods.split(RegExp(r'[,，\s]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
          final barsRaw = args['bars'];
          final bars = barsRaw is int ? barsRaw.clamp(100, chanBarCount) : 400;

          final az = await analyzer();

          // 并行：股票 × 周期 全部同时发，接口本身有缓存兜底。
          // 8 只 × 5 周期 = 40 个请求，全部并发容易触发限流。按股票分批，一次 4 只。
          // 两级限流：外层按股票 3 只，内层按周期 3 个 → 峰值 9 个请求。
          // 全放开的话 8 只 × 5 周期 = 40 个并发，容易被限流。
          final results = await mapLimit(
            list,
            3,
            (String sym) => mapLimit(
              periods,
              3,
              (String p) => az
                  .analyze(sym, period: p, count: bars)
                  .then<Map<String, dynamic>>(
                    (r) => {
                      'period': StockAnalyzer.periodName(p),
                      'bars': r.series.length,
                      'close': r.series.last.c,
                      'pens': r.chan.pens.length,
                      'boxes': r.chan.boxes.length,
                      'box_position': r.chan.stats.boxPosition,
                      'last_signals': [
                        for (final s in r.chan.signals.take(2))
                          {'label': s.label, 'price': r2(s.price), 'strength': s.strength},
                      ],
                      'last_points': [
                        for (final pt in r.chan.points.take(2)) {'label': pt.label, 'price': r2(pt.price)},
                      ],
                    },
                  )
                  .catchError((Object e) => {'period': p, 'error': '$e'}),
            ),
          );

          final payload = <String, dynamic>{
            'symbols': list,
            'levels': {for (var i = 0; i < list.length; i++) list[i]: results[i]},
            if (truncated) 'note': '一次最多 $maxSymbols 只，已截断。剩下的请再调一次。',
          };
          return jsonEncode(payload);
        } catch (e) {
          return jsonEncode({'error': '$e'});
        }
      },
    ),
    AppTool(
      name: 'stock_panel_show',
      displayName: '打开K线',
      description:
          '把 App 底部的 K 线面板切到指定股票和周期，用户能立刻看到你在分析的图。'
          '当你为用户分析某只股票、或要配合画线说明走势时调用它——'
          '分析完 A 股面板还停在 B 股，用户会困惑。'
          '同一只股票不必重复调用。',
      parameters: objectSchema(
        {
          'symbol': strProp('股票代码，如 300274 或 sh600519'),
          'period': strProp(
            '周期：minute/day/week/month/m60/m30/m15/m5，默认保持用户当前选择',
            enumValues: ['minute', 'day', 'week', 'month', 'm60', 'm30', 'm15', 'm5'],
          ),
        },
        required: ['symbol'],
      ),
      promptHint: '切面板是为用户服务，不是每次回答都要切；只在你确实在讨论这只股票时用。',
      execute: (args) async {
        try {
          final raw = '${args['symbol'] ?? ''}'.trim();
          if (raw.isEmpty) return jsonEncode({'error': '缺少 symbol'});

          final code = source.normalize(raw);
          final period = args['period']?.toString();
          final ok = await stockPanelRequest.show(code, period: period);
          if (!ok) return jsonEncode({'error': '面板切换失败'});

          return jsonEncode({
            'ok': true,
            'symbol': code,
            'period': period ?? 'unchanged',
            'note': 'K 线面板已切到该标的，用户现在能看到这张图',
          });
        } catch (e) {
          return jsonEncode({'error': '$e'});
        }
      },
    ),

    AppTool(
      name: 'get_fundamental',
      displayName: '基本面',
      description:
          '取一只股票的估值、财报、龙虎榜。\n'
          '  · 估值：PE(TTM)、PB、总市值、流通市值、换手率\n'
          '  · 财报：最近 4 期，营收/净利及同比、毛利率、ROE、EPS\n'
          '  · 龙虎榜：最近 5 次上榜，买卖额、上榜原因、机构动向、上榜后 5/10 日表现\n'
          '要判断「贵不贵」「业绩好不好」「有没有资金关注」就用它。\n'
          '⚠ 同比都是「去年同期」的报告期口径，不要说成环比。',
      parameters: objectSchema({'symbol': strProp('股票代码。不传则取面板当前标的')}),
      promptHint: '报表数字要带单位和报告期。ROE、毛利率这类比率要和同业比才有意义，不要孤立地说好坏。',
      execute: (args) async {
        try {
          final symbol = resolveSymbol(args['symbol']);
          if (symbol == null) return jsonEncode({'error': '缺少 symbol，且面板没有正在看的股票'});
          final f = await source.fundamental(symbol);
          return jsonEncode({
            'summary': renderFundamental(f),
            'detail': {
              'symbol': f.symbol,
              'name': f.name,
              'valuation': f.valuation == null
                  ? null
                  : {
                      'pe_ttm': f.valuation!.pe,
                      'pb': f.valuation!.pb,
                      'total_cap': f.valuation!.totalCap,
                      'float_cap': f.valuation!.floatCap,
                      'turnover_pct': f.valuation!.turnover,
                    },
              'reports': [
                for (final r in f.reports)
                  {
                    'period': r.period,
                    'eps': r.eps,
                    'revenue': r.revenue,
                    'revenue_yoy_pct': r.revenueYoy,
                    'net_profit': r.netProfit,
                    'net_profit_yoy_pct': r.netProfitYoy,
                    'gross_margin_pct': r.grossMargin,
                    'roe_pct': r.roe,
                  },
              ],
              'boards': [
                for (final b in f.boards)
                  {
                    'date': b.date,
                    'close': b.close,
                    'change_pct': b.changePct,
                    'buy_amt': b.buyAmt,
                    'sell_amt': b.sellAmt,
                    'ratio_pct': b.ratio,
                    'reason': b.reason,
                    'explain': b.explain,
                  },
              ],
              if (f.note != null) 'note': f.note,
            },
          });
        } catch (e) {
          return jsonEncode({'error': '$e'});
        }
      },
    ),

    AppTool(
      name: 'scan_stocks',
      displayName: '批量扫描',
      description:
          '批量扫描多只股票的当前状态，只返回摘要（现价、涨跌、缠论结构、买卖点），'
          '不返回 K 线明细——用来快速筛出值得深入看的那几只。\n'
          '需要详细分析时，再对筛出来的股票单独调 analyze_chan。',
      parameters: objectSchema(
        {
          'symbols': strProp('股票代码，多只用逗号分隔，如 300274,600519,000001，最多 20 只'),
          'period': strProp('分析周期，默认 day（批量扫描统一用一个周期，不跟随面板）', enumValues: ['day', 'week', 'm60', 'm30', 'm15']),
        },
        required: ['symbols'],
      ),
      promptHint: '扫描结果是筛选用的，不要逐只罗列。挑出符合条件的那几只说明理由，其余一句话带过。',
      execute: (args) async {
        try {
          final raw = '${args['symbols'] ?? ''}'.trim();
          if (raw.isEmpty) return jsonEncode({'error': '缺少 symbols'});
          final symbols = raw
              .split(RegExp(r'[,，\s]+'))
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toSet()
              .take(20)
              .toList();
          final period = '${args['period'] ?? 'day'}';

          final az = await analyzer();
          // 全部并行。单只失败不影响其他。
          // 20 只 × 2 请求 = 40 个并发，容易被限流。按股票分批，一次 6 只。
          final rows = await mapLimit(
            symbols,
            6,
            (String sym) =>
                Future.wait([
                  source.quoteCached(sym).then<Quote?>((q) => q).catchError((Object _) => null),
                  az
                      .analyze(sym, period: period, count: 400)
                      .then<StockAnalysis?>((r) => r)
                      .catchError((Object _) => null),
                ]).then((pair) {
                  final q = pair[0] as Quote?;
                  final r = pair[1] as StockAnalysis?;
                  if (r == null) {
                    return {'symbol': sym, 'error': '取数失败'};
                  }
                  return {
                    'symbol': r.series.symbol,
                    'name': r.series.name,
                    if (q != null) 'price': q.price,
                    if (q != null) 'change_pct': r2(q.changePct),
                    'close': r.series.last.c,
                    'boxes': r.chan.boxes.length,
                    'box_position': r.chan.stats.boxPosition,
                    'last_point': r.chan.points.isEmpty ? null : r.chan.points.last.label,
                    'last_point_price': r.chan.points.isEmpty ? null : r2(r.chan.points.last.price),
                    'last_signal': r.chan.signals.isEmpty ? null : r.chan.signals.last.label,
                  };
                }),
          );

          return jsonEncode({'period': StockAnalyzer.periodName(period), 'count': rows.length, 'results': rows});
        } catch (e) {
          return jsonEncode({'error': '$e'});
        }
      },
    ),

    AppTool(
      name: 'chart_annotate',
      displayName: '标注',
      description:
          '在 K 线图上画标注：水平线（支撑/压力/止损价）、趋势线、矩形区间、文字、箭头、圆点。\n'
          '用户看图比你说话快。只要你的回答里出现了具体价位、区间或走势判断，就应该画出来——'
          '让图和你说的对上，用户不用在文字和数字之间来回换算。\n'
          '典型用法：\n'
          '  · 提到「支撑 68.5」→ hline 画一条，配 text 写「支撑」\n'
          '  · 提到「中枢 ZG=71.74 ZD=62.24」→ rect 把区间框出来\n'
          '  · 提到「这个下跌笔要跌破 X 才失效」→ arrow 从当前价指向 X\n'
          '  · 提到「三买出现在某根」→ dot 标在那根上\n'
          '多次调用会累加，不会覆盖。',
      parameters: objectSchema(
        {
          'symbol': strProp('股票代码。不传则画在面板当前标的上'),
          'period': strProp('周期：day/week/month/m60/m30/m15，默认沿用面板周期'),
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
        required: ['shapes'],
      ),
      promptHint:
          '画完要说明每条线代表什么价位、为什么在这个位置，不要只报坐标。'
          '正文里提到的关键价位，图上都应该能找到对应的线。',
      execute: (args) async {
        try {
          final symbol = resolveSymbol(args['symbol']);
          if (symbol == null) return jsonEncode({'error': '缺少 symbol，且面板没有正在看的股票'});
          final pr = resolvePeriod(
            explicit: args['period'],
            panel: panelPeriod(),
            allowed: kAnalysisPeriods,
            toolLabel: 'chart_annotate',
          );
          if (!pr.isOk) return jsonEncode({'error': pr.error});
          final period = pr.value!;
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
            // 模型给的参数不一定都是数字：可能是 "72.5" 这样的字符串，
            // 甚至 "NaN"。强转会抛 TypeError 把整批图元搞挂，所以统一走宽容解析。
            final price = _num(item['price']);
            if (price == null) {
              rejected.add('$kindName 缺少有效的 price');
              continue;
            }
            final idx = resolveIndex(item['index'], total - 1);
            final needTwo =
                kind == ShapeKind.trendline ||
                kind == ShapeKind.rect ||
                kind == ShapeKind.arrow ||
                kind == ShapeKind.ray;
            final price2 = _num(item['price2']);
            if (needTwo && (item['index2'] == null || price2 == null)) {
              rejected.add('$kindName 需要 index2 和 price2');
              continue;
            }
            added.add(
              ChartShape(
                kind: kind,
                i1: idx,
                p1: price,
                i2: needTwo ? resolveIndex(item['index2'], idx) : null,
                p2: price2,
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

          // 如果画的正是面板当前那一屏，让它立刻重读，用户不用手动刷新
          if (stockPanelRequest.currentSymbol == series.symbol &&
              (stockPanelRequest.currentPeriod == null || stockPanelRequest.currentPeriod == period)) {
            stockPanelRequest.refreshShapes();
          }

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
