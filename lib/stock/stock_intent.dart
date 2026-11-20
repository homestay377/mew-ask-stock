/// 从用户原话里判断「这句话是不是在问股票」，以及可能指的是哪只。
///
/// 判定口径照搬 Eta 的 `StockChartLink`：
///  - 6 位代码（前后不能紧贴数字，避免把 12 位订单号当股票）
///  - 或者出现股票相关词
///
/// **只在「像在问股票」时才动面板**——这是 Eta 那边踩过的坑：
/// 早期条件是「面板开着就解析」，结果「你好」「继续」这类话都会触发一次搜索，
/// 问一句「帮我看看日历」还会把 K 线图弹出来。
library;

/// 6 位股票代码，前后不能紧跟其他数字。
final RegExp stockCodePattern = RegExp(r'(?<!\d)\d{6}(?!\d)');

/// 出现这些词就认为用户在问股票。
const List<String> stockHints = [
  '股票',
  '个股',
  '股价',
  '走势',
  '行情',
  '大盘',
  '分时',
  '日线',
  '周线',
  '月线',
  '涨停',
  '跌停',
  '收盘',
  '开盘',
  '加仓',
  '减仓',
  '持仓',
  '被套',
  '止盈',
  '止损',
  '买点',
  '卖点',
  '支撑',
  '压力',
  '背驰',
  '缠论',
  '分析一下',
  '帮我分析',
  '能不能买',
  '该买',
  'K线',
  'k线',
];

/// 说这些话时顺带切周期。
const Map<String, String> periodHints = {
  '分时': 'minute',
  '日线': 'day',
  '周线': 'week',
  '月线': 'month',
  '60分钟': 'm60',
  '60分': 'm60',
  '30分钟': 'm30',
  '30分': 'm30',
  '15分钟': 'm15',
  '15分': 'm15',
  '5分钟': 'm5',
  '5分': 'm5',
};

/// 这句话像不像在问股票。
bool looksLikeStockQuestion(String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  if (stockCodePattern.hasMatch(t)) return true;
  for (final h in stockHints) {
    if (t.contains(h)) return true;
  }
  return false;
}

/// 从原话里抽 6 位代码。没有返回 null。
String? extractStockCode(String text) {
  final m = stockCodePattern.firstMatch(text);
  return m?.group(0);
}

/// 从原话里识别要切换的周期。没有返回 null。
String? extractPeriod(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  for (final e in periodHints.entries) {
    if (t.contains(e.key)) return e.value;
  }
  return null;
}

/// 话题相关的完整判断：要不要为这句话动面板。
///
/// [panelOpen] 面板当前是否展开。面板没开、这句话又不像在问股票时，
/// 返回 false，连搜索都不该发出去。
bool shouldTouchPanel(String text, {required bool panelOpen}) {
  if (text.trim().isEmpty) return false;
  return panelOpen || looksLikeStockQuestion(text);
}
