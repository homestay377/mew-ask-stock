// 本地自检脚本（CI 不执行）：`dart run tool/market_router_check.dart`。
// market_router 是纯 Dart（不 import Flutter），所以不需要 flutter test 也能跑。
// ignore_for_file: avoid_print, avoid_relative_lib_imports
// 这些用例就是产品口径：面板画得出来的走接口，画不出来的走 App，聚合类走看板。
import '../lib/stock/market_router.dart';

int _fail = 0;

void _expectApi(String input, MarketKind kind) {
  final d = MarketRouter.decide(input);
  if (!d.isApi || d.kind != kind) {
    _fail++;
    print('✗ $input → ${d.route.name}/${d.kind.name}，期望 api/${kind.name}');
  }
}

void _expectApp(String input, MarketKind kind) {
  final d = MarketRouter.decide(input);
  if (d.isApi || d.kind != kind || (d.app ?? '').isEmpty) {
    _fail++;
    print('✗ $input → ${d.route.name}/${d.kind.name}/${d.app}，期望 app/${kind.name}');
  }
}

void _expectCode(String input, String code) {
  final d = MarketRouter.decide(input);
  if (d.code != code) {
    _fail++;
    print('✗ $input → code=${d.code}，期望 $code');
  }
}

void main() {
  // 面板画得出来：A 股 / 指数 / ETF
  _expectApi('300274', MarketKind.aShare);
  _expectApi('600519', MarketKind.aShare);
  _expectApi('sh600519', MarketKind.aShare);
  _expectApi('000001', MarketKind.aShare);
  _expectApi('688981', MarketKind.aShare);
  _expectApi('sh000001', MarketKind.indexQuote);
  _expectApi('sh000300', MarketKind.indexQuote);
  _expectApi('sz399006', MarketKind.indexQuote);
  _expectApi('510300', MarketKind.fund);
  _expectApi('159915', MarketKind.fund);
  _expectApi('上证指数', MarketKind.indexQuote);
  _expectApi('阳光电源', MarketKind.unknown);
  _expectApi('贵州茅台', MarketKind.unknown);
  _expectApi('黄金ETF', MarketKind.unknown);

  // 面板画不出来：外汇 / 贵金属 / 港股 / 美股 / 期货
  _expectApp('伦敦金', MarketKind.metal);
  _expectApp('现货黄金', MarketKind.metal);
  _expectApp('XAUUSD', MarketKind.metal);
  _expectApp('eurusd', MarketKind.fx);
  _expectApp('美元汇率', MarketKind.fx);
  _expectApp('hk00700', MarketKind.hk);
  _expectApp('usAAPL', MarketKind.us);
  _expectApp('螺纹钢主力', MarketKind.future);

  // 代码补前缀
  _expectCode('300274', 'sz300274');
  _expectCode('600519', 'sh600519');
  _expectCode('830799', 'bj830799');

  // 聚合类问题
  const topics = {
    '今天涨停几家？': 'limit_up',
    '连板天梯最高几板': 'limit_up',
    '板块涨幅排序': 'sector',
    '成交额排名前二十': 'rank',
    '今天赚钱效应怎么样': 'breadth',
  };
  topics.forEach((q, want) {
    final got = MarketRouter.aggregateTopic(q);
    if (got != want) {
      _fail++;
      print('✗ 「$q」→ $got，期望 $want');
    }
  });
  if (MarketRouter.aggregateTopic('300274 现在多少钱') != null) {
    _fail++;
    print('✗ 个股问题被误判成聚合类');
  }

  // 聚合类选 App：天梯走开盘啦
  if (MarketRouter.appForTopic('limit_up') != MarketRouter.appSentiment) {
    _fail++;
    print('✗ limit_up 没选开盘啦');
  }

  print(_fail == 0 ? '✓ 全部通过' : '✗ $_fail 条失败');
}
