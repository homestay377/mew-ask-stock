import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'mini_phone_channel.dart';

/// 虚拟屏通道的原生实现封装（对应 `android/.../shell/VirtualDisplayBridge.kt`）。
///
/// 和 [MiniPhoneChannel]（无障碍，操作**主屏**）并列：这一条走 Shizuku / 无线调试拿到的
/// shell 身份去建**虚拟屏**，App 在那块看不见的屏上运行，不打扰用户。
///
/// 原生方法返回 `Map`，必定带 `ok`（`status` 例外，它永远成功）。
class VirtualDisplayChannel {
  VirtualDisplayChannel({MethodChannel? channel}) : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'io.github.homestay377.mewaskstock/virtual_display';

  final MethodChannel _channel;

  /// Shizuku 装没装、跑没跑、有没有授权；虚拟屏建没建；无障碍连没连。
  Future<VirtualDisplayStatus> status() async {
    if (!Platform.isAndroid) return VirtualDisplayStatus.unsupported();
    final r = await _call('status');
    if (r['ok'] == false && r['error'] != null) return VirtualDisplayStatus.unsupported(detail: '${r['error']}');
    return VirtualDisplayStatus.fromMap(r);
  }

  Future<Map<String, dynamic>> requestPermission() => _call('request_permission');

  Future<Map<String, dynamic>> openShizuku() => _call('open_shizuku');

  Future<Map<String, dynamic>> refresh() => _call('refresh');

  /// 用配对码完成无线调试配对（B 路线第一步）。
  ///
  /// 用户的动作：系统设置 → 开发者选项 → 无线调试 → 使用配对码配对设备，
  /// 抄下 6 位码（对话框别关）。端口从 mDNS 自动发现，也可以手填 [port]。
  Future<Map<String, dynamic>> pairWireless(String code, {int? port}) =>
      _call('pair_wireless', args: {'code': code, 'port': ?port}, timeout: const Duration(seconds: 30));

  /// 开始一次配对：会**先把带输入框的通知放进通知栏**，
  /// 同时（无障碍开着时）自动读系统设置上的 6 位码。
  /// 用户不需要离开那个配对对话框。
  Future<Map<String, dynamic>> beginPairing({int? port}) =>
      _call('begin_pairing', args: {'port': ?port}, timeout: const Duration(seconds: 15));

  Future<Map<String, dynamic>> endPairing() => _call('end_pairing');

  /// 打开系统的开发者选项页（无线调试在它下面）。
  Future<Map<String, dynamic>> openWirelessSettings() => _call('open_wireless_settings');

  /// 配对之后拉起 shell 身份助手（B 路线第二步）。成功后再 ensureDisplay 就能建屏。
  Future<Map<String, dynamic>> startWireless() => _call('start_wireless', timeout: const Duration(seconds: 40));

  /// 解除无线调试配对（删掉本机私钥，下次要重新配）。
  Future<Map<String, dynamic>> forgetWireless() => _call('forget_wireless');

  /// 确保虚拟屏已建（内部会检查 shell 身份、调用 createVirtualDisplay）。
  Future<Map<String, dynamic>> ensureDisplay() => _call('ensure_display', timeout: const Duration(seconds: 25));

  Future<Map<String, dynamic>> releaseDisplay() => _call('release_display');

  /// 在虚拟屏上打开一个包。失败原因见 [openError]。
  Future<Map<String, dynamic>> startApp(String packageName) =>
      _call('start_app', args: {'package': packageName}, timeout: const Duration(seconds: 30));

  /// 在虚拟屏上点一下（坐标是那块屏自己的像素）。
  Future<Map<String, dynamic>> tap(int x, int y) => _call('tap', args: {'x': x, 'y': y});

  Future<Map<String, dynamic>> swipe(int x1, int y1, int x2, int y2, {int durationMs = 320}) =>
      _call('swipe', args: {'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2, 'durationMs': durationMs});

  /// back / enter / home / del
  Future<Map<String, dynamic>> pressKey(String key) => _call('press_key', args: {'key': key});

  /// 用**本机 OCR** 读虚拟屏上的文字，返回带坐标的行。
  ///
  /// 这条路**不需要无障碍**：画面经 ImageReader 进来，ML Kit 在本机识别，
  /// 每行带 `text` 和 `center`（虚拟屏像素），可直接用于 [tap]。
  Future<List<Map<String, dynamic>>> ocr() async {
    final r = await _call('ocr', timeout: const Duration(seconds: 25));
    if (r['ok'] != true) return const [];
    final lines = (r['lines'] as List?) ?? const [];
    return lines.map((e) => (e as Map).map((k, v) => MapEntry('$k', v))).toList();
  }

  /// 虚拟屏当前帧（base64 PNG）。App 还没启动时可能没有帧。
  Future<Uint8List?> screenshot() async {
    final r = await _call('screenshot');
    if (r['ok'] != true) return null;
    final b64 = r['base64'] as String?;
    if (b64 == null) return null;
    return base64Decode(b64);
  }

  Future<Map<String, dynamic>> topTask() => _call('top_task');

  Future<Map<String, dynamic>> _call(
    String method, {
    Map<String, dynamic>? args,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (!Platform.isAndroid) return {'ok': false, 'error': 'unsupported_platform'};
    try {
      final r = await _channel.invokeMethod<dynamic>(method, args).timeout(timeout);
      if (r is Map) return r.map((k, v) => MapEntry('$k', v));
      return {'ok': false, 'error': 'bad_response', 'message': '原生返回非 Map: $r'};
    } on PlatformException catch (e) {
      return {'ok': false, 'error': e.code, 'message': e.message ?? ''};
    } on MissingPluginException {
      return {'ok': false, 'error': 'channel_missing', 'message': '这个版本还没有虚拟屏通道'};
    } catch (e) {
      // timeout 等
      return {'ok': false, 'error': 'call_failed', 'message': '$e'};
    }
  }
}

/// 虚拟屏此刻的状态，供 UI 与模型判断"还差哪一步"。
class VirtualDisplayStatus {
  VirtualDisplayStatus({
    required this.shizuku,
    required this.shizukuReady,
    required this.shizukuDetail,
    this.shizukuRunning = false,
    this.shizukuGranted = false,
    this.shizukuText,
    this.wireless = 'not_paired',
    this.wirelessReady = false,
    this.wirelessDetail,
    this.source = 'none',
    required this.displayReady,
    required this.displayId,
    required this.displayPhase,
    required this.displayDetail,
    required this.accessibility,
  });

  /// not_installed / not_running / need_permission / binding / ready / failed
  final String shizuku;
  final bool shizukuReady;
  final String? shizukuDetail;

  /// 服务在不在跑、授没授权——分开报，避免把"服务没起来"说成"没授权"。
  final bool shizukuRunning;
  final bool shizukuGranted;

  /// 原生给的一句话（准确说出缺哪一步），有就用它。
  final String? shizukuText;

  /// 无线调试助手的状态：no_key / not_paired / pairing / connecting / ready / failed
  final String wireless;
  final bool wirelessReady;
  final String? wirelessDetail;

  /// 当前用的是哪条路：none / shizuku / wireless
  final String source;

  final bool displayReady;
  final int displayId;
  final String displayPhase;
  final String? displayDetail;

  final bool accessibility;

  factory VirtualDisplayStatus.unsupported({String? detail}) => VirtualDisplayStatus(
    shizuku: 'unsupported',
    shizukuReady: false,
    shizukuDetail: detail,
    displayReady: false,
    displayId: -1,
    displayPhase: 'unavailable',
    displayDetail: detail,
    accessibility: false,
  );

  factory VirtualDisplayStatus.fromMap(Map<String, dynamic> m) {
    final d = (m['display'] as Map?)?.map((k, v) => MapEntry('$k', v)) ?? const <String, dynamic>{};
    return VirtualDisplayStatus(
      shizuku: '${m['shizuku'] ?? 'unknown'}',
      shizukuReady: m['shizukuReady'] == true,
      shizukuRunning: m['shizukuRunning'] == true,
      shizukuGranted: m['shizukuGranted'] == true,
      shizukuDetail: m['shizukuDetail']?.toString(),
      shizukuText: m['shizukuText']?.toString(),
      wireless: '${m['wireless'] ?? 'not_paired'}',
      wirelessReady: m['wirelessReady'] == true,
      wirelessDetail: m['wirelessDetail']?.toString(),
      source: '${m['source'] ?? 'none'}',
      displayReady: d['ok'] == true,
      displayId: (d['displayId'] as num?)?.toInt() ?? -1,
      displayPhase: '${d['phase'] ?? 'idle'}',
      displayDetail: d['detail']?.toString(),
      accessibility: m['accessibility'] == true,
    );
  }

  /// 一句话说清现在能不能用、缺什么，直接给模型和用户看。
  String describe() {
    if (displayReady) {
      return '虚拟屏已就绪（display=$displayId，shellUid=${shizukuReady ? "2000" : "?"}）'
          '${accessibility ? "，无障碍已连" : "，无障碍未连（读不到界面文字）"}';
    }
    if (shizukuReady || wirelessReady) {
      return '服务已就绪（${source == 'wireless' ? "无线调试助手" : "Shizuku"}），但虚拟屏没建起来'
          '${displayDetail == null ? "" : "：$displayDetail"}';
    }
    if (shizukuText != null && shizukuText!.isNotEmpty) {
      // 原生把「服务没跑」和「没授权」分开了，直接用它的说法
      final w = wirelessReady || wireless == 'ready' ? '；无线调试：已就绪' : '';
      return '$shizukuText$w';
    }
    switch (shizuku) {
      case 'unsupported':
        return '这台设备/这个版本不支持虚拟屏';
      case 'not_installed':
        return '需要先安装并启动 Shizuku（或用无线调试配对），才能建虚拟屏';
      case 'not_running':
        return 'Shizuku 已安装但服务没在运行：打开 Shizuku 让它启动起来';
      case 'need_permission':
        return '需要在 Shizuku 里给「问股」授权（会在弹窗里问一次）';
      case 'binding':
        return '正在绑定 Shizuku 服务…';
      case 'failed':
        return 'Shizuku 绑定失败${shizukuDetail == null ? "" : "：$shizukuDetail"}';
      case 'ready':
        return 'Shizuku 已连接，但虚拟屏没建起来${displayDetail == null ? "" : "：$displayDetail"}';
      default:
        return '虚拟屏状态未知';
    }
  }

  bool get usable => displayReady;
}
