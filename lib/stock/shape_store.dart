/// 画线的持久化：按「代码|周期」分别存到 SharedPreferences。
///
/// 与模型层分开，是为了让 [chart_shapes.dart] 不依赖 Flutter，
/// 纯 Dart 环境也能对序列化逻辑做回归测试。
library;

import 'dart:convert';

import 'dart:io';

import '../../core/paths.dart';
import 'chart_shapes.dart';
import 'numbers.dart';

/// 画线持久化：按「代码|周期」分别存。
///
/// 存在 `AppPaths.support/shapes.json` 一个文件里，键是 `代码|周期`。
/// 不依赖 shared_preferences——MewHub 本身没有这个包，也没必要为它加依赖。
class ShapeStore {
  ShapeStore._();

  static final ShapeStore instance = ShapeStore._();

  static const _fileName = 'stock_shapes.json';

  Map<String, ShapeBundle>? _all;
  Future<void>? _loading;

  String _key(String code, String period) => '$code|$period';

  File _file() => File('${AppPaths.support.path}/$_fileName');

  Future<Map<String, ShapeBundle>> _ensure() {
    final hit = _all;
    if (hit != null) return Future.value(hit);
    final running = _loading;
    if (running != null) return running.then((_) => _all!);
    final f = _read();
    _loading = f;
    return f.then((_) => _all!);
  }

  Future<void> _read() async {
    final out = <String, ShapeBundle>{};
    try {
      final f = _file();
      if (await f.exists()) {
        final raw = await f.readAsString();
        if (raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            for (final e in decoded.entries) {
              final v = e.value;
              // 新格式：{date, shapes}；旧格式：直接是数组（那时还没记日期）
              final bundle = v is List ? ShapeBundle.fromLegacyList(v) : ShapeBundle.fromJson(v);
              if (bundle != null) out['${e.key}'] = bundle;
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
      // ★ tmp 名必须唯一：同一文件的两次并发写（比如后台刷新 + 前台保存）
      //   如果共用一个 .tmp，会互相覆盖，rename 时还可能拿到半个文件。
      final tmp = File('${f.path}.${nextTmpSeq()}.tmp');
      await tmp.writeAsString(jsonEncode({for (final e in all.entries) e.key: e.value.toJson()}), flush: true);
      await tmp.rename(f.path);
    } catch (_) {
      // 写失败只影响下次启动的持久化，本次会话仍可用
    }
  }

  /// 读当前这个「代码|周期」的画线。
  ///
  /// [currentBarDate] 传当前最后一根 K 线的日期（`yyyy-MM-dd`）。
  /// 跨日了就把整组删掉再返回空——旧线的索引已经跟着滚动窗口位移，
  /// 继续画在图上只会误导人。拿不到日期时保持原样，不乱删。
  Future<List<ChartShape>> load(
    String code,
    String period, {
    String? currentBarDate,
    String? currentStamp,
    bool intraday = false,
  }) async {
    final all = await _ensure();
    final k = _key(code, period);
    final bundle = all[k];
    if (bundle == null) return const [];
    if (bundle.staleFor(currentBarDate, currentStamp: currentStamp, intraday: intraday)) {
      all.remove(k);
      await _write();
      return const [];
    }
    return bundle.shapes;
  }

  Future<void> save(String code, String period, List<ChartShape> shapes, {String? barDate, String? barStamp}) async {
    final all = await _ensure();
    all[_key(code, period)] = ShapeBundle(shapes: List<ChartShape>.from(shapes), barDate: barDate, barStamp: barStamp);
    await _write();
  }

  Future<void> clear(String code, String period) async {
    final all = await _ensure();
    all.remove(_key(code, period));
    await _write();
  }
}
