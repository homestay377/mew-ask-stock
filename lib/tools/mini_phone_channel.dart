import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// 手机操控通道的原生实现封装。
///
/// Kotlin 侧见 `android/app/src/main/kotlin/io/github/homestay377/mewaskstock/miniphone/`。
/// 所有方法返回 `Map`，必定带 `ok`；出错时带 `error`（机器码）与 `message`（给人看的一句话）。
///
/// 设计原则：**原生只提供原子动作，决策在 Dart 的模型循环里做**。
/// 这里不做"点这里再点那里"的编排，也不缓存屏幕状态——每次 [observe] 都是一次真实读屏，
/// 因为手机界面随时被用户动。
class MiniPhoneChannel {
  MiniPhoneChannel({MethodChannel? channel}) : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'io.github.homestay377.mewaskstock/mini_phone';

  final MethodChannel _channel;

  /// 无障碍服务是否已开启（用户需要在系统设置里手动开）。
  Future<bool> connected() async {
    if (!Platform.isAndroid) return false;
    final r = await _call('status');
    return r['connected'] == true;
  }

  /// SDK 版本（低于 30 时截图、多窗口读屏不可用）。
  Future<int> sdk() async {
    if (!Platform.isAndroid) return 0;
    final r = await _call('status');
    return (r['sdk'] as num?)?.toInt() ?? 0;
  }

  /// 读屏：返回 `{ok, package, size:[w,h], elements:[...], windows:[...]}`。
  ///
  /// `elements` 每条：`{ref, role, name, center:[x,y], bounds:[l,t,r,b], clickable, editable, scrollable, focused, checked, enabled}`。
  /// `ref` 只在这一次读屏内有效，下一次读屏会重新编号。
  Future<Map<String, dynamic>> observe({bool resourceIds = false}) => _call('observe', {'resourceIds': resourceIds});

  Future<Map<String, dynamic>> tapRef(String ref) => _call('tap_ref', {'ref': ref});

  Future<Map<String, dynamic>> tap(int x, int y) => _call('tap', {'x': x, 'y': y});

  Future<Map<String, dynamic>> longPress(int x, int y, {int durationMs = 600}) =>
      _call('long_press', {'x': x, 'y': y, 'durationMs': durationMs});

  Future<Map<String, dynamic>> swipe(int x1, int y1, int x2, int y2, {int durationMs = 300}) =>
      _call('swipe', {'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2, 'durationMs': durationMs});

  Future<Map<String, dynamic>> typeText(String ref, String text, {bool clear = false}) =>
      _call('type_text', {'ref': ref, 'text': text, 'clear': clear});

  Future<Map<String, dynamic>> back() => _call('back');

  Future<Map<String, dynamic>> home() => _call('home');

  Future<Map<String, dynamic>> recents() => _call('recents');

  Future<Map<String, dynamic>> openApp(String package) => _call('open_app', {'package': package});

  Future<Map<String, dynamic>> openUrl(String url, {String? package}) =>
      _call('open_url', {'url': url, 'package': package});

  /// 跳系统的无障碍设置页，方便用户一步打开。
  Future<Map<String, dynamic>> openAccessibilitySettings() => _call('open_settings');

  Future<Map<String, dynamic>> _call(String method, [Map<String, dynamic>? args]) async {
    if (!Platform.isAndroid) {
      return {'ok': false, 'error': 'unsupported_platform'};
    }
    try {
      final r = await _channel.invokeMethod<dynamic>(method, args);
      if (r is Map) return r.map((k, v) => MapEntry('$k', v));
      return {'ok': false, 'error': 'bad_response', 'message': '原生返回了非 Map：$r'};
    } on PlatformException catch (e) {
      return {'ok': false, 'error': e.code, 'message': e.message ?? ''};
    } on MissingPluginException {
      return {'ok': false, 'error': 'channel_missing', 'message': '这个版本的原生还没有手机操控通道'};
    }
  }
}

/// 把一次读屏结果裁剪成"给模型看"的紧凑文本：省 token，又保留可点的位置。
///
/// 只保留有名字或可交互的元素（原生已经过滤），再按名字去重相邻重复行（列表滚动时的重复条目）。
String renderScreenForModel(Map<String, dynamic> screen, {int maxElements = 80}) {
  // 两个来源都会进来：MethodChannel 的 Map 和测试里手写的字面量（可能是 Map<Object?, Object?>）。
  // 统一转成 Map<String, dynamic>，否则 screen['ok'] 取不到，会误报"读屏失败"。
  final s = screen.map((k, v) => MapEntry(k.toString(), v as dynamic));
  if (s['ok'] != true) {
    return '读屏失败：${s['error'] ?? 'unknown'}${s['message'] == null ? '' : '（${s['message']}）'}';
  }
  final pkg = s['package']?.toString();
  final size = (s['size'] as List?)?.join('×') ?? '?';
  final raw = (s['elements'] as List?) ?? const [];
  final buf = StringBuffer('屏幕：${pkg ?? '未知 App'}（$size），共 ${raw.length} 个元素');
  if (raw.length > maxElements) buf.write('，只列前 $maxElements 个');
  buf.writeln();
  var shown = 0;
  String? lastLine;
  for (final e in raw) {
    if (shown >= maxElements) break;
    final m = (e as Map).cast<String, dynamic>();
    final name = (m['name'] ?? '').toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    final role = (m['role'] ?? '').toString();
    final flags = <String>[
      if (m['clickable'] == true) '可点',
      if (m['editable'] == true) '可输入',
      if (m['scrollable'] == true) '可滚动',
      if (m['checked'] == true) '已选中',
      if (m['enabled'] == false) '不可用',
    ];
    final center = (m['center'] as List?) ?? const [0, 0];
    final line = '${m['ref']} $role「$name」@${center[0]},${center[1]}${flags.isEmpty ? '' : ' [${flags.join(' ')}]'}';
    // 列表滚动常出现连续同名条目，只留第一条
    if (line == lastLine) continue;
    buf.writeln(line);
    lastLine = line;
    shown++;
  }
  return buf.toString().trimRight();
}

/// 给模型解析用的 JSON（需要结构化参数时用它）。
String screenJson(Map<String, dynamic> screen) => jsonEncode(screen);
