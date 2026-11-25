import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 保活 + 悬浮图标（Android）。
///
/// 为什么要有：虚拟屏、Shizuku 绑定、无障碍连接都挂在 App 进程上，而小米这类系统
/// 在后台待久了会按"重要程度"把进程收掉。Android 上真正管用的是**前台服务 + 常驻通知**，
/// 再配一颗悬浮图标（App 自己的图标）让人随时看得到"它现在在干什么"、点一下回到 App。
///
/// 悬浮窗权限不麻烦用户自己去点：原生侧会先拿 shell 身份 `appops set … allow`，
/// 拿不到才退回去开系统授权页。
class KeepAlive {
  KeepAlive._();

  static const _channel = MethodChannel('io.github.homestay377.mewaskstock/keep_alive');
  static const _vd = MethodChannel('io.github.homestay377.mewaskstock/virtual_display');

  /// 开始按住进程，并把当前动作写到通知/悬浮图标上。
  static Future<bool> start(String status) async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      // 先让 shell 身份把悬浮窗权限点掉（appops），用户不用自己去系统设置里翻
      await _vd.invokeMethod<void>('grant_overlay');
    } catch (_) {
      // 没有 shell 身份也没关系，下面 start 会退回去开授权页
    }
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('start', {'status': status});
      return r?['overlay'] == true;
    } catch (e) {
      debugPrint('keep alive start failed: $e');
      return false;
    }
  }

  /// 更新"正在干什么"（不动保活本身）。
  static Future<void> status(String status) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('status', {'status': status});
    } catch (_) {
      // 保活只是锦上添花，失败不打断对话
    }
  }

  /// 撤掉保活和悬浮图标（一轮对话结束时）。
  static Future<void> stop() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }
}
