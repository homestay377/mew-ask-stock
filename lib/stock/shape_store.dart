/// 画线的持久化：按「代码|周期」分别存到 SharedPreferences。
///
/// 与模型层分开，是为了让 [chart_shapes.dart] 不依赖 Flutter，
/// 纯 Dart 环境也能对序列化逻辑做回归测试。
library;

import 'dart:convert';

import 'dart:io';

import '../../core/paths.dart';
import 'chart_shapes.dart';

/// 画线持久化：按「代码|周期」分别存。
///
/// 存在 `AppPaths.support/shapes.json` 一个文件里，键是 `代码|周期`。
/// 不依赖 shared_preferences——MewHub 本身没有这个包，也没必要为它加依赖。
class ShapeStore {
  ShapeStore._();

  static final ShapeStore instance = ShapeStore._();

  static const _fileName = 'stock_shapes.json';

  Map<String, List<ChartShape>>? _all;
  Future<void>? _loading;

  String _key(String code, String period) => '$code|$period';

  File _file() => File('${AppPaths.support.path}/$_fileName');

  Future<Map<String, List<ChartShape>>> _ensure() {
    final hit = _all;
    if (hit != null) return Future.value(hit);
    final running = _loading;
    if (running != null) return running.then((_) => _all!);
    final f = _read();
    _loading = f;
    return f.then((_) => _all!);
  }

  Future<void> _read() async {
    final out = <String, List<ChartShape>>{};
    try {
      final f = _file();
      if (await f.exists()) {
        final raw = await f.readAsString();
        if (raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            for (final e in decoded.entries) {
              final list = e.value;
              if (list is List) {
                out['${e.key}'] = [
                  for (final x in list)
                    if (x is Map) ChartShape.fromJson(x.cast<String, dynamic>()),
                ];
              }
            }
          }
        }
      }
    } catch (_) {
      // 读坏了就当空的，不影响看图
    }
    _all = out;
  }

  Future<void> _write() async {
    try {
      final all = _all;
      if (all == null) return;
      final f = _file();
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          for (final e in all.entries) e.key: [for (final s in e.value) s.toJson()],
        }),
        flush: true,
      );
      await tmp.rename(f.path);
    } catch (_) {
      // 写失败只影响下次启动的持久化，本次会话仍可用
    }
  }

  Future<List<ChartShape>> load(String code, String period) async {
    final all = await _ensure();
    return all[_key(code, period)] ?? const [];
  }

  Future<void> save(String code, String period, List<ChartShape> shapes) async {
    final all = await _ensure();
    all[_key(code, period)] = List<ChartShape>.from(shapes);
    await _write();
  }

  Future<void> clear(String code, String period) async {
    final all = await _ensure();
    all.remove(_key(code, period));
    await _write();
  }
}
