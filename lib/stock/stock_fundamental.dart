/// 基本面数据：估值、财报、龙虎榜。
///
/// 数据源是东财公开接口（免登录），选择依据见 `docs/data-sources.md`：
///  - 估值：`push2delay.eastmoney.com/api/qt/stock/get`
///  - 财报：`datacenter-web.eastmoney.com` 的 `RPT_LICO_FN_CPD`
///  - 龙虎榜：`RPT_DAILYBILLBOARD_DETAILSNEW`
///
/// **口径比数字更重要**。这里刻意只用「报告期口径」的同比字段（YSTZ / SJLTZ），
/// 不用实时行情里那个 f184：后者是滚动/单季口径，和财报同比对不上
/// （实测同一天 300274：f184 = -26.41%，YSTZ = 32.95%）。
/// 混用会让模型把两个口径当成同一个数，结论就错了。
library;

/// 估值指标。
class Valuation {
  Valuation({this.pe, this.pb, this.totalCap, this.floatCap, this.turnover, this.roe});

  /// 市盈率（动态）
  final double? pe;

  /// 市净率
  final double? pb;

  /// 总市值（元）
  final double? totalCap;

  /// 流通市值（元）
  final double? floatCap;

  /// 换手率（%）
  final double? turnover;

  /// ROE（%）
  final double? roe;

  bool get isEmpty => pe == null && pb == null && totalCap == null;
}

/// 一期财报。
class Report {
  Report({
    required this.period,
    this.eps,
    this.revenue,
    this.revenueYoy,
    this.netProfit,
    this.netProfitYoy,
    this.grossMargin,
    this.roe,
    this.bps,
    this.cashPerShare,
  });

  /// 报告期，如 `2025-09-30`
  final String period;
  final double? eps;

  /// 营业总收入（元）
  final double? revenue;

  /// 营收同比（%），**报告期口径**
  final double? revenueYoy;

  /// 归母净利润（元）
  final double? netProfit;

  /// 归母净利润同比（%），**报告期口径**
  final double? netProfitYoy;

  /// 销售毛利率（%）
  final double? grossMargin;

  /// 加权 ROE（%）
  final double? roe;

  /// 每股净资产
  final double? bps;

  /// 每股经营现金流
  final double? cashPerShare;
}

/// 一次龙虎榜记录。
class BillBoard {
  BillBoard({
    required this.date,
    this.close,
    this.changePct,
    this.buyAmt,
    this.sellAmt,
    this.dealAmt,
    this.ratio,
    this.reason,
    this.explain,
    this.next1,
    this.next2,
    this.next5,
    this.next10,
  });

  final String date;
  final double? close;
  final double? changePct;

  /// 龙虎榜买入额（元）
  final double? buyAmt;

  /// 龙虎榜卖出额（元）
  final double? sellAmt;

  /// 龙虎榜成交总额（元）
  final double? dealAmt;

  /// 占当日总成交额比例（%）
  final double? ratio;

  /// 上榜原因，如「日涨幅达到15%的前5只证券」
  final String? reason;

  /// 机构动向描述，如「4家机构买入，成功率42.46%」
  final String? explain;

  /// 上榜后 1 / 2 / 5 / 10 日涨跌幅（%）
  final double? next1;
  final double? next2;
  final double? next5;
  final double? next10;
}

/// 一只股票的完整基本面。
class Fundamental {
  Fundamental({
    required this.symbol,
    required this.name,
    this.valuation,
    this.reports = const [],
    this.boards = const [],
    this.note,
  });

  final String symbol;
  final String name;
  final Valuation? valuation;
  final List<Report> reports;
  final List<BillBoard> boards;

  /// 拿不到数据时的说明（ETF/指数没有财报、或接口失败）。
  final String? note;

  bool get hasReport => reports.isNotEmpty;
  bool get hasBoard => boards.isNotEmpty;
}

/// 把大数字读成「亿 / 万」，给模型看更省 token，也不容易读错量级。
String fmtMoney(double? v) {
  if (v == null || !v.isFinite) return '—';
  final abs = v.abs();
  if (abs >= 1e8) return '${(v / 1e8).toStringAsFixed(2)}亿';
  if (abs >= 1e4) return '${(v / 1e4).toStringAsFixed(2)}万';
  return v.toStringAsFixed(2);
}

/// 百分比，保留两位。
String fmtPct(double? v) {
  if (v == null || !v.isFinite) return '—';
  return '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}%';
}

/// 普通数字，保留两位。
String fmtNum(double? v) {
  if (v == null || !v.isFinite) return '—';
  return v.toStringAsFixed(2);
}

/// 渲染成给模型读的中文摘要。
///
/// 数字都带单位（亿/万/%），并明确标注口径，避免模型把「报告期同比」
/// 和「实时滚动同比」混为一谈。
String renderFundamental(Fundamental f) {
  final b = StringBuffer();
  b.writeln('【${f.name} ${f.symbol} · 基本面】');

  final v = f.valuation;
  if (v != null && !v.isEmpty) {
    final parts = <String>[];
    if (v.pe != null) parts.add('PE(TTM) ${fmtNum(v.pe)}');
    if (v.pb != null) parts.add('PB ${fmtNum(v.pb)}');
    if (v.totalCap != null) parts.add('总市值 ${fmtMoney(v.totalCap)}');
    if (v.floatCap != null) parts.add('流通 ${fmtMoney(v.floatCap)}');
    if (v.turnover != null) parts.add('换手 ${fmtNum(v.turnover)}%');
    b.writeln('估值：${parts.join(' · ')}');
  }

  if (f.hasReport) {
    b.writeln('财报（按报告期倒序，同比口径均为「去年同期」）：');
    for (final r in f.reports) {
      b.writeln(
        '  ${r.period}  '
        '营收 ${fmtMoney(r.revenue)}（同比 ${fmtPct(r.revenueYoy)}）  '
        '净利 ${fmtMoney(r.netProfit)}（同比 ${fmtPct(r.netProfitYoy)}）',
      );
      final extra = <String>[];
      if (r.grossMargin != null) extra.add('毛利率 ${fmtNum(r.grossMargin)}%');
      if (r.roe != null) extra.add('ROE ${fmtNum(r.roe)}%');
      if (r.eps != null) extra.add('EPS ${fmtNum(r.eps)}');
      if (r.bps != null) extra.add('每股净资产 ${fmtNum(r.bps)}');
      if (r.cashPerShare != null) extra.add('每股现金流 ${fmtNum(r.cashPerShare)}');
      if (extra.isNotEmpty) b.writeln('        ${extra.join('  ')}');
    }
  }

  if (f.hasBoard) {
    b.writeln('龙虎榜（最近 ${f.boards.length} 次）：');
    for (final x in f.boards) {
      b.writeln(
        '  ${x.date}  收 ${fmtNum(x.close)} 涨 ${fmtPct(x.changePct)}  '
        '净买 ${fmtMoney((x.buyAmt ?? 0) - (x.sellAmt ?? 0))}  '
        '占成交 ${fmtNum(x.ratio)}%',
      );
      if (x.reason != null && x.reason!.isNotEmpty) b.writeln('        上榜原因：${x.reason}');
      if (x.explain != null && x.explain!.isNotEmpty) b.writeln('        机构动向：${x.explain}');
      final after = <String>[];
      if (x.next1 != null) after.add('次日 ${fmtPct(x.next1)}');
      if (x.next2 != null) after.add('2日 ${fmtPct(x.next2)}');
      if (x.next5 != null) after.add('5日 ${fmtPct(x.next5)}');
      if (x.next10 != null) after.add('10日 ${fmtPct(x.next10)}');
      if (after.isNotEmpty) b.writeln('        上榜后：${after.join('  ')}');
    }
    b.writeln('⚠ 上榜后涨跌幅是历史统计，不代表这次也会这样。');
  }

  final note = f.note;
  if (note != null && note.isNotEmpty) {
    b.writeln('说明：$note');
    b.writeln('⚠ 拿不到的数据不要猜，直接告诉用户查不到。');
  }

  return b.toString().trimRight();
}
