/// 对话与 K 线面板之间的联动。
///
/// 用户发一句话时，如果这句话像在问股票，就把面板切到对应标的和周期。
/// 判定全部走 [stock_intent]，这里只负责「执行」。
///
/// 设计上刻意保守：
///  - 面板没开、这句话又不像在问股票 → 什么都不做（连搜索都不发）
///  - 有 6 位代码 → 直接切，不联网
///  - 只有名称 → 才走一次搜索，且失败静默
library;

import 'package:flutter/foundation.dart';

import '../../stock/stock_intent.dart';
import '../../stock/stock_search.dart';
import '../../stock/stock_source.dart';
import 'stock_chart_panel.dart';

/// 与面板、AI 工具共用同一个数据源，缓存和连接才能真正复用。
StockSource get _source => sharedStockSource;

/// 最近一次联动解析出的代码，供测试与调试查看。
@visibleForTesting
String? lastLinkedCode;

/// 从一段用户输入里联动 K 线面板。
///
/// 返回是否真的动了面板，便于调用方记日志或测试。
Future<bool> linkStockPanel(String text) async {
  if (!shouldTouchPanel(text, panelOpen: stockPanel.expanded)) return false;

  final code = extractStockCode(text);
  if (code != null) {
    // 有明确代码：直接切，不联网。
    final normalized = _normalize(code);
    if (normalized == null) return false;
    _apply(normalized, text);
    return true;
  }

  // 没有代码：尝试按名称搜索一次。
  final hit = await _searchByName(text);
  if (hit == null) return false;
  _apply(hit.fullCode, text, name: hit.name);
  return true;
}

void _apply(String fullCode, String text, {String? name}) {
  lastLinkedCode = fullCode;
  stockPanel.ensureExpanded();
  stockPanel.setSymbol(fullCode, name: name);

  // 顺带切周期（「看看日线」「切到30分钟」）
  final period = extractPeriod(text);
  if (period != null) stockPanel.setPeriod(period);
}

/// 6 位纯数字补市场前缀。
String? _normalize(String code) {
  if (code.length != 6) return null;
  final c = code[0];
  if (c == '6' || c == '9') return 'sh$code';
  if (c == '4' || c == '8') return 'bj$code';
  return 'sz$code';
}

/// 从原话里挑出最像的那只股票。
///
/// 策略：把话里所有 2~4 字的中文片段拿去搜，取第一个能搜到 A 股的结果。
/// 只在「像在问股票」时才被调用，所以不需要额外的保守判断。
Future<StockHit?> _searchByName(String text) async {
  // 去掉标点，按可能的词切
  final cleaned = text.replaceAll(RegExp(r'[，。！？、,.!?\s]+'), ' ');
  final candidates = <String>[];

  // 先试整句里较长的中文串
  for (final seg in cleaned.split(' ')) {
    if (seg.length < 2) continue;
    candidates.add(seg);
  }
  // 再试每段的前 2~4 字（覆盖「阳光电源走势」这种带后缀的写法）
  for (final seg in cleaned.split(' ')) {
    if (seg.length < 2) continue;
    for (final n in [4, 3, 2]) {
      if (seg.length >= n) candidates.add(seg.substring(0, n));
    }
  }

  final seen = <String>{};
  for (final c in candidates) {
    if (!seen.add(c)) continue;
    try {
      final hits = await _source.search(c);
      if (hits.isEmpty) continue;
      // 命中名字必须真的出现在原话里，防止「看看」搜出「看看科技」之类的误切
      for (final h in hits) {
        if (text.contains(h.name)) return h;
      }
    } catch (_) {
      // 搜索失败不影响对话，继续试下一个
    }
  }
  return null;
}
