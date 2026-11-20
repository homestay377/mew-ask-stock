/// 工具层与 K 线面板之间的桥。
///
/// 工具（`lib/tools/stock_tools.dart`）不该直接 import UI，面板也不需要知道工具的存在，
/// 所以中间放一个可替换的请求器：App 启动时把面板的实现注入进来。
///
/// 这样做还有一个好处：**测试里可以换成假实现**，不必启动界面就能验证工具行为。
library;

import '../stock/stock_search.dart';

/// 面板请求接口。
abstract class StockPanelRequest {
  /// 把面板切到 [code]，可选切 [period]。返回是否成功。
  Future<bool> show(String code, {String? period});

  /// 当前面板是否可见（供模型判断要不要再切）。
  bool get visible;
}

/// 默认实现：什么都不做（未接入 UI 时调用工具不会崩）。
class _NoopStockPanelRequest implements StockPanelRequest {
  @override
  Future<bool> show(String code, {String? period}) async => false;

  @override
  bool get visible => false;
}

StockPanelRequest _impl = _NoopStockPanelRequest();

/// 供工具层使用。
StockPanelRequest get stockPanelRequest => _impl;

/// App 启动时注入真实实现。
void installStockPanelRequest(StockPanelRequest impl) {
  _impl = impl;
}

/// 工具层搜索股票（避免工具直接依赖 StockSource 的实例管理）。
typedef StockSearchFn = Future<List<StockHit>> Function(String keyword);
