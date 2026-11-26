/// 股票分析工具：把 `lib/stock/` 的能力暴露给模型。
///
/// 挂载点：`ChatController._collectTools()` 里 `...buildStockTools(...)`。
/// 与 MewHub 原有工具完全同构（`AppTool`），不需要碰工具循环本身。
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../core/util.dart';
import '../stock/chanlun.dart';
import '../stock/chart_shapes.dart';
import '../stock/data_quality.dart';
import '../stock/market_source.dart';
import '../stock/stock_bridge.dart';
import '../stock/shape_store.dart';
import '../stock/stock_analyzer.dart';
import '../stock/numbers.dart';
import '../stock/period_resolver.dart';
import '../stock/stock_fundamental.dart';
import '../stock/market_router.dart';
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

/// 面板画不出来、接口也取不到的标的，别硬取。
///
/// 以前是三级降级跑满 72 秒（3 源 × 2 次 × 12 秒）再报「行情源都失败了」：
/// 用户看到的是转圈，模型看到的是「取不到」。这里先分诊，
/// 该走 App 的直接把路指出来，省一轮工具调用和一分钟等待。
/// 返回 null 表示这是接口能覆盖的标的，继续正常取数。
String? routeAway(String symbol) {
  final d = MarketRouter.decide(symbol);
  if (d.isApi) return null;
  return jsonEncode({
    'error': '${d.kind.label}「$symbol」不在本地行情接口的覆盖范围，K 线面板也画不出来。',
    'route': 'app',
    'app': d.app,
    'reason': d.reason,
    'next':
        '用 vd_open 打开「${d.app}」，搜「$symbol」，再用 vd_observe 读界面文字；'
        '这类品种不做缠论与多周期计算，也不要把界面上读到的数字说成接口取的。',
  });
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

  final market = MarketSource();

  return [
    AppTool(
      name: 'market_overview',
      displayName: '大盘与市场',
      description: '''看今天的市场全貌。可选模块（默认全开）：
- indices：上证/深成/创业板/科创50（数据走腾讯，不封 IP）
- sectors：板块涨幅榜或跌幅榜（**按涨跌幅 change_pct 排序**），附带主力净流入 net_inflow_yi（东财）
- limit_up：涨停家数与涨停股列表，含连板数（东财）
- margin：最近几日两市融资融券余额（东财）
- billboard：最近一个交易日龙虎榜（东财）
- hot：热门榜——东财人气榜 + 同花顺热榜（带题材归因）

只做实测确认可用的接口。每个数字都带 as_of 或 date，盘中数据会变。
取不到的模块会在 errors 里写明原因（多为东财限流），**不要用别的模块的数据反推**。''',
      parameters: objectSchema({
        'modules': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': '要哪些模块，可选 indices/sectors/limit_up/margin/billboard/hot；留空表示全开',
        },
        'sector_direction': strProp('板块榜方向', enumValues: ['up', 'down']),
        'limit': intProp('每类返回条数，默认 8，上限 20'),
      }),
      promptHint:
          '「今天涨得最好的板块」= 按 change_pct 从高到低，取 sectors 数组前几条；'
          '**不要按 net_inflow_yi（主力净流入）排序**，那会给出完全不同的名单。'
          '回答里引用板块时写清涨跌幅数字与该板块的领涨股，不要只写板块名。'
          '市场问题里的指数、板块、涨停数、两融、龙虎榜、热榜数字必须来自这个工具，不要凭印象说「今天普涨」。'
          '每个数字都要注明时间（as_of / date）与来源模块名。'
          'errors 里出现的模块就是取不到，如实说明，不要用板块涨幅去反推涨停家数这类指标。'
          '注意：北向资金的逐日净额接口当前返回全 0（额度披露已停），不要把它当有效数据用。',
      execute: (args) async {
        final wanted = asList(args['modules'])
            .map((e) => asStr(e).trim().toLowerCase())
            .where((e) => e.isNotEmpty)
            .toSet();
        bool on(String name) => wanted.isEmpty || wanted.contains(name);
        final dir = asStr(args['sector_direction']).trim().toLowerCase() == 'down' ? false : true;
        final limit = (args['limit'] is int ? args['limit'] as int : 8).clamp(1, 20).toInt();

        final errors = <String, String>{};
        final payload = <String, dynamic>{
          'source': {'indices': '腾讯 qt.gtimg.cn（不封 IP）', 'others': '东方财富（有风控，已串行限流）'},
        };

        if (on('indices')) {
          final r = await market.indices();
          payload['indices'] = r.items;
          if (r.error != null) errors['indices'] = r.error!;
        }
        if (on('sectors')) {
          final r = await market.sectors(descending: dir, limit: limit);
          payload['sectors_title'] = dir ? '涨幅榜' : '跌幅榜';
          payload['sectors'] = r.items;
          payload['sector_total'] = r.total;
          // 排序语义必须显式给出：涨跌幅才是「涨得最好」的依据，
          // net_inflow_yi（主力净流入）只是附带字段，不是排序字段。
          payload['sectors_sorted_by'] = r.sortedBy;
          payload['sectors_order'] = r.order;
          if (!r.monotonic) payload['sectors_note'] = '接口返回顺序不单调，已在本地按涨跌幅重排';
          if (r.error != null) errors['sectors'] = r.error!;
        }
        if (on('limit_up')) {
          final r = await market.limitUpPool(limit: limit);
          payload['limit_up_count'] = r.count;
          payload['limit_up'] = r.items;
          if (r.error != null) errors['limit_up'] = r.error!;
        }
        if (on('margin')) {
          final r = await market.margin(limit: 3);
          payload['margin'] = r.items;
          if (r.error != null) errors['margin'] = r.error!;
        }
        if (on('billboard')) {
          final r = await market.billboard(limit: limit);
          payload['billboard'] = r.items;
          if (r.error != null) errors['billboard'] = r.error!;
        }
        if (on('hot')) {
          final ths = await market.popularityThs(limit: limit);
          payload['hot_ths'] = ths.items;
          if (ths.error != null) errors['hot_ths'] = ths.error!;
          final east = await market.popularityEast(limit: limit);
          payload['hot_east'] = east.items;
          if (east.error != null) errors['hot_east'] = east.error!;
        }

        if (errors.isNotEmpty) payload['errors'] = errors;
        payload['unavailable'] = ['北向资金逐日净额（接口返回全 0，额度披露已停）', '连板梯队细分（只有每只股的连板数）'];
        return jsonEncode(payload);
      },
    ),
    AppTool(
      name: 'chart_context',
      displayName: '当前图表',
      description:
          '读取用户此刻正在看的 K 线图：标的、周期、数据源、可视范围、'
          '十字光标选中的那一根 K 线及其当前指标值、缠论结构摘要。\n'
          '当用户说「这根」「现在这个图」「当前指标」「我选中这个」时，'
          '先调它拿到真实数据，不要根据文字猜他在看什么。\n'
          '无需参数，返回的就是面板当前状态。',
      parameters: objectSchema({}),
      promptHint:
          '回答里引用具体日期和数值时，必须来自这个工具的结果；'
          '没选中某根时就说明「当前没有选中 K 线」，不要编。'
          '读 adjust 确认复权口径（不复权的序列不能当连续历史用）；'
          'last_bar_closed=false 说明最后一根还在走，别把它的收盘价当定值；'
          'from_cache=true 且 cache_age 较大时，说明用户看到的是旧数据。',
      execute: (args) async {
        try {
          final ctx = await stockPanelRequest.snapshot();
          if (ctx == null) {
            return jsonEncode({
              'error':
                  'K 线面板没有打开或还没有数据。可以让用户先打开图表，'
                  '或者直接用 stock_kline / analyze_chan 按代码和周期取数。',
            });
          }
          return jsonEncode({'text': ctx.renderText(), 'detail': ctx.toJson()});
        } catch (e) {
          return jsonEncode({'error': '$e'});
        }
      },
    ),

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
      promptHint:
          '取到 K 线后先看趋势方向和关键价位，再谈结论；不要凭一根 K 线下判断。'
          '回答里要顺带说清数据来历：`data.source`（腾讯/新浪/东财）、`data.adjust`（前复权 / 不复权）、'
          '`data.closed` 是不是已收盘。`data.from_cache=true` 说明这不是刚拉的，'
          '`data.quality.ok=false` 时要把 issues 说出来并给结论打折，别当成干净数据用。',
      execute: (args) async {
        try {
          final symbol = resolveSymbol(args['symbol']);
          if (symbol == null) return jsonEncode({'error': '缺少 symbol，且面板没有正在看的股票'});
          final away = routeAway(symbol);
          if (away != null) return away;
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
            'first_date': displayBarTime(s.period, s.first.t),
            'last_date': displayBarTime(s.period, s.last.t),
            'ma5': r2(maOf(5)),
            'ma10': r2(maOf(10)),
            'ma20': r2(maOf(20)),
            'ma60': r2(maOf(60)),
            // 数据来历 + 质量：缺了这三行，「当前价位」就成了无源之水
            'data': {
              'source': s.source,
              'adjust': s.adjust,
              if (s.fallbackReason != null) 'degraded_reason': s.fallbackReason,
              ...s.clock.toJson(),
              'from_cache': s.fromCache,
              'cache_age': s.cacheAge == null ? null : humanAge(s.cacheAge!),
              'quality': s.quality.toJson(),
            },
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
          '要说清它成立的条件和失效的价位。'
          '`last.is_intraday=true` 说明最后一根还没收盘：它的价格会一直漂，'
          '不能当收盘价、也不能当「现状」写进结论（要写就写「盘中价，收盘后需重取」）。'
          '背驰信号带 `macd_area_prev` / `macd_area_cur`，面积比可以直接自己算，'
          '不要再说「面积是公式内部算的无法复算」。'
          '中枢与买卖点都带 `date`，引用时写日期，不要只写索引。'
          '不要跨工具比较中枢「个数」：不同工具用的 K 线根数不同，个数本来就会变；'
          '要看个数就用 `bars_used` 自己核对。'
          '`repaints=true` 是 BACKSET 的固有行为：中枢右端会随新 K 线后延，'
          '图上看到的结构不等于当时就能确认的结构，报告里要写明这一点。',
      execute: (args) async {
        try {
          final symbol = resolveSymbol(args['symbol']);
          if (symbol == null) return jsonEncode({'error': '缺少 symbol，且面板没有正在看的股票'});
          final away = routeAway(symbol);
          if (away != null) return away;
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
          final away = routeAway(symbol);
          if (away != null) return away;
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
            // 腾讯给的是 20261120161454 这种 14 位串，直接读没法看
            'as_of': _fmtStamp14(q.time),
            // 降级到备源会标出来：东财是延迟行情，不能当实时价用。
            if (q.fallbackReason != null) 'degraded_reason': q.fallbackReason,
            if (q.delayed) 'note': '这份快照来自备源（东财延迟行情），不是实时价',
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
          '多级别结论按这个顺序组织，缺一不可：\n'
          '1) 大级别（周线）趋势是什么；\n'
          '2) 日线当前处在什么位置（中枢上方/内/下方）；\n'
          '3) 60 分钟与日线方向是否一致——不一致时说明以哪一级别为准、为什么；\n'
          '4) 值得关注的关键价位或结构；\n'
          '5) 哪些条件会支持或推翻当前判断。\n'
          '不要把各周期的买卖信号数一数、加个权——那没有意义。矛盾就直说矛盾。'
          '如果返回里有 bars_adequate=false，说明该周期数据不够，结论要打折扣。'
          '各级别若 source / adj 不同（比如某一级降级到了新浪的不复权数据），'
          '不能当成同一口径来比，要说明差异。'
          '多只股票对比要给出横向排序依据，而不是逐只念一遍。',
      execute: (args) async {
        try {
          final rawSymbols = '${args['symbols'] ?? args['symbol'] ?? ''}'.trim();
          if (rawSymbols.isEmpty) return jsonEncode({'error': '缺少 symbols'});

          final symbols = rawSymbols.split(RegExp(r'[,，\s]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
          if (symbols.isEmpty) return jsonEncode({'error': 'symbols 解析后为空'});
          // 多级别对照只对接口覆盖的标的成立；混进外汇/黄金会让整次调用白跑。
          final unsupported = symbols.where((s) => !MarketRouter.decide(s).isApi).toList();
          if (unsupported.isNotEmpty) return routeAway(unsupported.first)!;

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
                      'period_key': p,
                      'bars': r.series.length,
                      'close': r2(r.series.last.c),
                      'last_date': displayBarTime(p, r.series.last.t),
                      // 数据源与复权口径：跨周期对照时不能把不同源的数据直接拼起来
                      'source': r.series.source,
                      'adj': r.series.adjust,
                      if (r.series.fallbackReason != null) 'degraded_reason': r.series.fallbackReason,
                      'closed': r.series.clock.closed,
                      'data_age': r.series.clock.age == null ? null : humanAge(r.series.clock.age!),
                      'quality_ok': r.series.quality.ok,
                      if (r.series.quality.issues.isNotEmpty) 'quality_issues': r.series.quality.issues,
                      // 结构需要足够历史才收敛（实测 400 根起）；不足时结论不稳
                      'bars_adequate': r.series.length >= 400,
                      'trend': trendOf(r.chan.pens),
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
                      if (r.chan.unknownFunctions.isNotEmpty) 'formula_gaps': r.chan.unknownFunctions,
                    },
                  )
                  .catchError((Object e) => {'period': p, 'error': '$e'}),
            ),
          );

          // 跨周期冲突检测：只看「大级别 vs 小级别」方向是否相反。
          // 不做加权、不做计数——提案明确说过不要机械加权，
          // 矛盾本身就值得单独说，而不是被平均掉。
          final conflicts = <String, List<String>>{};
          for (var i = 0; i < list.length; i++) {
            final levels = {for (final m in results[i]) '${m['period_key'] ?? ''}': m};
            final found = <String>[];
            void cmp(String a, String b, String label) {
              final ta = levels[a]?['trend'];
              final tb = levels[b]?['trend'];
              if (ta == null || tb == null) return;
              if (ta == '数据不足' || tb == '数据不足') return;
              if (ta != tb && (ta == '上升' || ta == '下降') && (tb == '上升' || tb == '下降')) {
                found.add('${levels[a]?['period']}($ta) 与 ${levels[b]?['period']}($tb) $label');
              }
            }

            cmp('week', 'day', '方向相反');
            cmp('day', 'm60', '方向相反');
            cmp('day', 'm30', '方向相反');
            if (found.isNotEmpty) conflicts[list[i]] = found;
          }

          final payload = <String, dynamic>{
            'symbols': list,
            'levels': {for (var i = 0; i < list.length; i++) list[i]: results[i]},
            if (conflicts.isNotEmpty) 'conflicts': conflicts,
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
          final away = routeAway(symbol);
          if (away != null) return away;
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
          // 扫描是 A 股内部的事：混进外汇/黄金只会让 20 只全报「取数失败」。
          final unsupported = symbols.where((s) => !MarketRouter.decide(s).isApi).toList();
          if (unsupported.isNotEmpty) return routeAway(unsupported.first)!;
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
          '多次调用会累加，不会覆盖。\n'
          '画线按「这一根 K 线」作锚点：跨交易日（分钟线是走完新的一根）会自动清空，'
          '因为滚动窗口会让旧线的索引位移。所以不要说「这条线会一直留着」。',
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
          final away = routeAway(symbol);
          if (away != null) return away;
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
          // 读的时候把「这组线属于哪一天」一起带上：跨日会整组作废
          final barDate = barDateOf(series.last.t);
          final existing = await ShapeStore.instance.load(
            series.symbol,
            period,
            currentBarDate: barDate,
            currentStamp: series.last.t,
            intraday: minutesOfPeriod(period) != null,
          );

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
          await ShapeStore.instance.save(series.symbol, period, next, barDate: barDate, barStamp: series.last.t);

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

/// 腾讯快照时间戳 `20261120161454` → `2026-11-20 16:14:54`。格式不符原样返回。
String? _fmtStamp14(String? t) {
  if (t == null || t.length < 14 || int.tryParse(t) == null) return t;
  return '${t.substring(0, 4)}-${t.substring(4, 6)}-${t.substring(6, 8)} '
      '${t.substring(8, 10)}:${t.substring(10, 12)}:${t.substring(12, 14)}';
}
