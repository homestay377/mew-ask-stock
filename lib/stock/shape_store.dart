/// 画线的持久化：按「代码|周期」分别存到 SharedPreferences。
///
/// 与模型层分开，是为了让 [chart_shapes.dart] 不依赖 Flutter，
/// 纯 Dart 环境也能对序列化逻辑做回归测试。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'chart_shapes.dart';

/// 画线持久化：按 `代码|周期` 分别存。
class ShapeStore {
  ShapeStore._();

  static final ShapeStore instance = ShapeStore._();

  final Map<String, List<ChartShape>> _cache = {};

  String _key(String code, String period) => '$code|$period';
  String _prefKey(String code, String period) => 'stock_shapes_${_key(code, period)}';

  Future<List<ChartShape>> load(String code, String period) async {
    final k = _key(code, period);
    final hit = _cache[k];
    if (hit != null) return hit;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_prefKey(code, period));
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw);
        if (list is List) {
          final out = [
            for (final e in list)
              if (e is Map) ChartShape.fromJson(e.cast<String, dynamic>()),
          ];
          _cache[k] = out;
          return out;
        }
      }
    } catch (_) {
      // 读失败按空处理，不影响看图
    }
    _cache[k] = [];
    return _cache[k]!;
  }

  Future<void> save(String code, String period, List<ChartShape> shapes) async {
    _cache[_key(code, period)] = shapes;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_prefKey(code, period), jsonEncode([for (final s in shapes) s.toJson()]));
    } catch (_) {
      // 存失败就只保留内存里的，本次会话仍可用
    }
  }

  Future<void> clear(String code, String period) async {
    _cache[_key(code, period)] = [];
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_prefKey(code, period));
    } catch (_) {}
  }
}
