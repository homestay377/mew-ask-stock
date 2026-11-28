/// 缠论结果的进程内共享缓存。
///
/// 为什么要有：面板（`ui/stock/stock_chart_panel.dart`）和 AI 工具
/// （`stock/stock_analyzer.dart`）原来各跑一遍 `Chanlun.analyze`。
/// 同一只股票、同一个周期、同一批 K 线，屏幕上画的中枢和模型说的是
/// **两次独立计算**的结果——只要有一处输入不同（公式缓存不同、bar 数不同），
/// 就会出现「图上是这个、话里是那个」，而且没有任何地方会报警。
///
/// 现在两边都从这里取：键是「代码|根数|最后一根时间戳|公式指纹|load|viewStart」，
/// 最后一根时间变了（新 K 线到）或公式变了就自然失效，不需要手动清理。
library;

import 'chanlun.dart';

class _Entry {
  _Entry(this.result, this.at);

  final ChanResult result;
  final DateTime at;
}

final Map<String, _Entry> _cache = <String, _Entry>{};

/// 最多留几份。面板切股时最多同时用 2–3 只，加工具的多周期，20 足够。
const _maxEntries = 20;

/// 超过这个时间就重算（同一根 K 线内结果不会变，这里只是兜底内存增长）。
const _maxAge = Duration(minutes: 10);

/// 公式文本的轻量指纹。只看长度和前 64 个字符，足以区分不同公式，
/// 又不用把整份 22KB 的公式塞进缓存键。
String _formulaKey(String formula) {
  final head = formula.length <= 64 ? formula : formula.substring(0, 64);
  return '${formula.length}:$head';
}

/// 取缠论结果；缓存命中就直接返回，不重复计算。
///
/// [bars] 只用于生成键和计算，调用方必须保证它是**同一批**数据——
/// 键里的最后一根时间就是干这个的。
ChanResult analyzeShared(
  List<Bar> bars,
  String formula, {

  /// ★ 周期必须进键：日线和周线可能都是 640 根、最后一根都是同一天，
  /// 不写周期就会互相命中——表现是「周线结论和日线逐位相同」。
  String period = '',
  int load = 0,
  int viewStart = 0,
  String? symbol,
  String? name,
}) {
  if (bars.isEmpty) {
    return Chanlun.analyze(bars, formula, load: load, viewStart: viewStart, symbol: symbol, name: name);
  }

  final key = [
    symbol ?? '',
    period,
    bars.length,
    // 原始时间戳比任何格式化都稳：最后一根变了（新 K 线到）键就变。
    bars.last.t,
    _formulaKey(formula),
    load,
    viewStart,
  ].join('|');

  final hit = _cache[key];
  if (hit != null && DateTime.now().difference(hit.at) < _maxAge) {
    return hit.result;
  }

  final result = Chanlun.analyze(bars, formula, load: load, viewStart: viewStart, symbol: symbol, name: name);
  _cache[key] = _Entry(result, DateTime.now());
  if (_cache.length > _maxEntries) {
    // 丢掉最旧的一批，不必精确 LRU：这里存的是纯计算结果，重算也就几百毫秒。
    final keys = _cache.keys.toList();
    for (var i = 0; i < _cache.length - _maxEntries; i++) {
      _cache.remove(keys[i]);
    }
  }
  return result;
}

/// 清空缓存（测试用，或数据源整体刷新后）。
void clearChanCache() => _cache.clear();

/// 当前缓存条目数（诊断用）。
int get chanCacheSize => _cache.length;
