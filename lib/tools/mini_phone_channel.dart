import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';


/// 无障碍通道：读屏 / 点击 / 输入。
///
/// 两种模式共用这一套方法，只差 `displayId`：
/// - `displayId = -1`（默认）：操作**用户主屏**，界面会动，适合"就一下"；
/// - `displayId = <虚拟屏号>`：操作**虚拟屏**，不动用户屏幕，读屏走
///   `getWindowsOnAllDisplays[displayId]`。
class MiniPhoneChannel {
  MiniPhoneChannel({MethodChannel? channel, this.defaultDisplayId = -1})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'io.github.homestay377.mewaskstock/mini_phone';

  final MethodChannel _channel;

  /// 不显式传 displayId 时用哪块屏；-1 表示主屏。
  final int defaultDisplayId;

  Future<bool> connected() async {
    if (!Platform.isAndroid) return false;
    final r = await _call('status');
    return r['connected'] == true;
  }

  Future<int> sdk() async {
    if (!Platform.isAndroid) return 0;
    final r = await _call('status');
    return (r['sdk'] as num?)?.toInt() ?? 0;
  }

  Future<Map<String, dynamic>> observe({bool resourceIds = false, int? displayId}) => _call('observe', {
    'resourceIds': resourceIds,
    if ((displayId ?? defaultDisplayId) >= 0) 'displayId': displayId ?? defaultDisplayId,
  });

  Future<Map<String, dynamic>> tapRef(String ref) => _call('tap_ref', {'ref': ref});

  Future<Map<String, dynamic>> tap(int x, int y) => _call('tap', {'x': x, 'y': y});

  Future<Map<String, dynamic>> longPress(int x, int y, {int durationMs = 600}) =>
      _call('long_press', {'x': x, 'y': y, 'durationMs': durationMs});

  Future<Map<String, dynamic>> swipe(int x1, int y1, int x2, int y2, {int durationMs = 300}) =>
      _call('swipe', {'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2, 'durationMs': durationMs});

  Future<Map<String, dynamic>> typeText(String ref, String text, {bool clear = false, int? displayId}) =>
      _call('type_text', {'ref': ref, 'text': text, 'clear': clear});

  Future<Map<String, dynamic>> back() => _call('back');
  Future<Map<String, dynamic>> home() => _call('home');
  Future<Map<String, dynamic>> recents() => _call('recents');

  /// 列出可启动的 App（名字 + 包名）。虚拟屏开 App 前先靠它把名字解析成包名。
  Future<Map<String, dynamic>> listApps() => _call('list_apps');

  /// 按名字/包名找 App；找不到时返回相近的候选（`suggest`）。
  Future<Map<String, dynamic>> findApp(String query) => _call('find_app', {'query': query});

  Future<Map<String, dynamic>> openApp(String package) => _call('open_app', {'package': package});

  Future<Map<String, dynamic>> openUrl(String url, {String? package}) =>
      _call('open_url', {'url': url, 'package': package});

  Future<Map<String, dynamic>> openAccessibilitySettings() => _call('open_settings');

  Future<Map<String, dynamic>> _call(String method, [Map<String, dynamic>? args]) async {
    if (!Platform.isAndroid) return {'ok': false, 'error': 'unsupported_platform'};
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
/// 纯函数、不依赖 Flutter：既能在 App 里跑，也能单独用 dart 跑（`tool/mini_phone_render_check.dart`）。
String renderScreenForModel(Map<Object?, Object?> screen, {int maxElements = 80}) {
  // 两个来源都会进来：MethodChannel 的 Map 和测试里手写的字面量（可能是 Map<Object?, Object?>）。
  // 统一转成 Map<String, dynamic>，否则 screen['ok'] 取不到，会误判成"读屏失败"。
  final s = <String, dynamic>{};
  screen.forEach((k, v) => s['$k'] = v);
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
    // 列表滚动常出现连续同名条目（各自的 ref 不同），只留第一条：
    // 去重看的是"角色 + 名字 + 坐标"，不看 ref
    final key = '$role|$name|${center[0]},${center[1]}';
    if (key == lastLine) continue;
    buf.writeln(line);
    lastLine = key;
    shown++;
  }
  return buf.toString().trimRight();
}

/// 给模型解析用的 JSON（需要结构化参数时用它）。
String screenJson(Map<String, dynamic> screen) => jsonEncode(screen);
