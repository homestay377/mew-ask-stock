/// 行情取数分诊：判断一个标的（或一类问题）该走本地接口，还是走虚拟屏里的 App。
///
/// 产品口径（用户定义，别自己改）：
/// 1. **K 线面板画得出来的标的** —— A 股、指数、ETF/LOF —— 走接口。
///    数据是结构化的，能算缠论、能对照多周期、能画到图上。
/// 2. **面板画不出来的标的** —— 外汇、伦敦金、港股、美股、期货 —— 走同花顺。
///    读界面文字，不做结构计算，也不假装有 K 线接口。
/// 3. **靠多只股票汇总才成立的大势结论** —— 涨停家数、连板天梯、板块排序、
///    成交额排名、涨跌分布 —— 接口只能给一部分，主力口径在 App 里，
///    走同花顺 / 开盘啦。
///
/// 这一层只做判断：不取数、不碰界面、不 import Flutter，
/// 所以是纯 Dart，可以在测试里直接跑。
library;

/// 数据从哪来。
enum MarketRoute {
  /// 走 [StockSource] 的原生取数。
  api('接口'),

  /// 走虚拟屏里的 App 界面。
  app('App');

  const MarketRoute(this.label);

  final String label;
}

/// 标的大类。只用来出原因和选 App，不参与取数。
enum MarketKind {
  aShare('A股'),
  indexQuote('指数'),
  fund('ETF/LOF'),
  hk('港股'),
  us('美股'),
  fx('外汇'),
  metal('贵金属'),
  future('期货'),
  unknown('未识别');

  const MarketKind(this.label);

  final String label;
}

/// 一次分诊的结果。
class MarketDecision {
  const MarketDecision(this.route, this.kind, {this.code, this.reason = '', this.app});

  final MarketRoute route;
  final MarketKind kind;

  /// 规范化后的代码。只有 api 路线才是确定的（纯 6 位数字会被补上 sh/sz/bj）。
  final String? code;

  /// 给模型看的一句话：为什么这么走。
  final String reason;

  /// app 路线建议打开哪个 App（中文名，交给 vd_open 的名字解析）。
  final String? app;

  bool get isApi => route == MarketRoute.api;

  Map<String, dynamic> toJson() => {
    'route': route.name,
    'kind': kind.label,
    if (code != null) 'code': code,
    if (app != null) 'app': app,
    if (reason.isNotEmpty) 'reason': reason,
  };
}

/// 分诊规则集中在这里，别在工具里各写一份。
class MarketRouter {
  const MarketRouter._();

  /// 个股 / 外汇 / 黄金：同花顺的覆盖面最全。
  static const appStock = '同花顺';

  /// 连板天梯、情绪温度：开盘啦做得比同花顺细。
  static const appSentiment = '开盘啦';

  static const _metalWords = ['伦敦金', '现货黄金', '黄金', '白银', '贵金属', '金银', 'xauusd', 'xagusd'];

  static const _fxWords = [
    'usdcny',
    'usdcnh',
    'eurusd',
    'gbpusd',
    'usdjpy',
    'audusd',
    'nzdusd',
    'usdcad',
    'usdchf',
    '美元',
    '欧元',
    '日元',
    '英镑',
    '汇率',
    '外汇',
  ];

  static const _futureWords = ['螺纹', '铁矿', '沪铜', '沪金', '沪银', '原油', '焦炭', '期货'];

  static const _indexWords = ['上证指数', '深证成指', '创业板指', '沪深300', '中证500', '中证1000', '科创50', '北证50'];

  /// 判断一个标的走哪条路。
  ///
  /// 非空判断优先于所有规则：给的既不是代码也不是名字时，
  /// 交给现有 `normalize()` 去报错，别在这里猜。
  static MarketDecision decide(String? raw) {
    final s = (raw ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (s.isEmpty) {
      return const MarketDecision(MarketRoute.api, MarketKind.unknown, reason: '没给代码：交给现有解析；解析不出来它会直接报「无法识别」。');
    }

    // 0) 纯代码优先：词表不该把 6 位代码抢走。
    if (RegExp(r'^(sh|sz|bj)\d{6}$').hasMatch(s)) return _decideCode(s);
    if (RegExp(r'^\d{6}$').hasMatch(s)) {
      final c = s[0];
      final prefix = (c == '6' || c == '9')
          ? 'sh'
          : (c == '4' || c == '8')
          ? 'bj'
          : 'sz';
      return _decideCode('$prefix$s');
    }
    if (RegExp(r'^hk\d{4,5}$').hasMatch(s)) return _app(MarketKind.hk, s);

    final hasCjk = RegExp(r'[\u4e00-\u9fff]').hasMatch(s);

    // 1) 带 ETF/LOF 的中文名先摘出来，别被「黄金ETF」里的「黄金」带走。
    if (hasCjk && (s.contains('etf') || s.contains('lof') || s.contains('基金'))) {
      return const MarketDecision(
        MarketRoute.api,
        MarketKind.unknown,
        reason: '带 ETF/LOF 的中文名：先用 stock_search 换成代码，再取数。',
      );
    }

    // 2) 词表对中英文一视同仁：xauusd 和「伦敦金」都是贵金属。
    if (_hit(s, _metalWords)) return _app(MarketKind.metal, raw!.trim());
    if (_hit(s, _futureWords)) return _app(MarketKind.future, raw!.trim());
    if (_hit(s, _fxWords)) return _app(MarketKind.fx, raw!.trim());

    // 3) 境外代码：腾讯能透传，但面板只画 A 股/ETF/指数，按口径走 App。
    if (s.startsWith('us') && s.length > 2) return _app(MarketKind.us, s);

    // 4) 中文指数名在接口覆盖范围内。
    if (_hit(s, _indexWords)) {
      return const MarketDecision(
        MarketRoute.api,
        MarketKind.indexQuote,
        reason: '指数在接口覆盖范围内，先用 stock_search 换成 sh000001 这种代码再取数。',
      );
    }

    if (hasCjk) {
      return const MarketDecision(MarketRoute.api, MarketKind.unknown, reason: '中文名：先解析成代码，解析成功再取数。');
    }

    return const MarketDecision(MarketRoute.api, MarketKind.unknown, reason: '不是标准代码：交给现有 normalize()，它会报「无法识别」。');
  }

  /// 面板能画的代码：指数 / ETF-LOF / A 股，都是接口。
  static MarketDecision _decideCode(String code) {
    if (code.startsWith('sh000') || code.startsWith('sz399')) {
      return MarketDecision(MarketRoute.api, MarketKind.indexQuote, code: code, reason: '指数：腾讯/新浪/东财都有，面板能画。');
    }
    final six = code.substring(2);
    if (isFundCode(six)) {
      return MarketDecision(MarketRoute.api, MarketKind.fund, code: code, reason: 'ETF/LOF：接口有行情，面板能画。');
    }
    return MarketDecision(MarketRoute.api, MarketKind.aShare, code: code, reason: 'A 股：面板能画，走接口。');
  }

  /// 场内基金：沪 50/51/56/58，深 15/16/18。
  static bool isFundCode(String six) =>
      six.startsWith('51') ||
      six.startsWith('56') ||
      six.startsWith('58') ||
      six.startsWith('50') ||
      six.startsWith('15') ||
      six.startsWith('16') ||
      six.startsWith('18');

  /// 大势类问题：靠的不是一只股票，而是整张市场表。
  ///
  /// 返回 null 表示这不是聚合类问题，该怎么答就怎么答。
  static String? aggregateTopic(String? text) {
    final s = text ?? '';
    if (s.trim().isEmpty) return null;
    if (_hit(s, ['涨停', '跌停', '连板', '天梯', '晋级', '炸板', '封板'])) return 'limit_up';
    if (_hit(s, ['板块', '行业', '概念', '题材', '轮动'])) return 'sector';
    if (_hit(s, ['成交额', '成交量排名', '龙虎榜', '活跃股', '换手率排名'])) return 'rank';
    if (_hit(s, ['两融', '融资余额', '北向', '外资'])) return 'margin';
    if (_hit(s, ['涨跌家数', '赚钱效应', '情绪', '大盘', '普涨', '普跌'])) return 'breadth';
    return null;
  }

  /// 聚合问题的首选 App：连板天梯只有情绪类 App 做得全。
  static String appForTopic(String topic) => topic == 'limit_up' ? appSentiment : appStock;

  /// 给模型看的路由说明。放在工具描述里，省得每次都要在系统提示里重复。
  static String get ruleSummary =>
      '取数三条路，按这个顺序选：\n'
      '1) 面板画得出来的（A 股、指数、ETF/LOF）→ stock_kline / analyze_chan / stock_levels。\n'
      '2) 面板画不出来的（外汇、伦敦金、港股、美股、期货）→ vd_open 打开「$appStock」读界面；'
      '这类品种不做缠论。\n'
      '3) 靠整张市场表才成立的结论（涨停家数、连板天梯、板块排序、成交额排名、涨跌分布）'
      '→ market_board，它按题目选「$appSentiment」或「$appStock」。';

  static bool _hit(String s, List<String> words) => words.any(s.contains);

  static MarketDecision _app(MarketKind kind, String raw) => MarketDecision(
    MarketRoute.app,
    kind,
    app: appStock,
    reason: '${kind.label}「$raw」不在本地行情接口的覆盖范围，K 线面板也画不出来：走虚拟屏里的 $appStock 读界面。',
  );
}
