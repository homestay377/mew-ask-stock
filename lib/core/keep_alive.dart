import 'dart:async';

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
///
/// ⚠ 这里每个 invokeMethod 都必须带超时。原生侧一起服务没起来（或 Shizuku 正在重连），
/// Future 就永远不完成，而 `ensureReady()` 会一直 await 它 —— 表现是工具卡到超时，
/// 整轮对话什么都不剩。保活是锦上添花，宁可放弃也不能拖住主流程。
class KeepAlive {
  KeepAlive._();

  static const _channel = MethodChannel('io.github.homestay377.mewaskstock/keep_alive');
  static const _vd = MethodChannel('io.github.homestay377.mewaskstock/virtual_display');

  /// appops 授权：拿不到就算了，1.5 秒足够原生返回，卡住说明服务有问题。
  static const _grantTimeout = Duration(milliseconds: 1500);

  /// 起前台服务：要跑 startForeground 和通知，给 4 秒。
  static const _startTimeout = Duration(seconds: 4);

  /// 更新通知文字：纯 UI 操作，1 秒足够。
  static const _statusTimeout = Duration(seconds: 1);

  /// 停服务：不能因为停不掉就卡住一轮对话的收尾，1.5 秒。
  static const _stopTimeout = Duration(milliseconds: 1500);

  /// 开始按住进程，并把当前动作写到通知/悬浮图标上。
  static Future<bool> start(String status) async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      // 先让 shell 身份把悬浮窗权限点掉（appops），用户不用自己去系统设置里翻
      await _vd.invokeMethod<void>('grant_overlay').timeout(_grantTimeout);
    } catch (e) {
      // 没有 shell 身份也没关系，下面 start 会退回去开授权页
      if (e is TimeoutException) debugPrint('keep alive: grant_overlay 超时，跳过');
    }
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('start', {'status': status}).timeout(_startTimeout);
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
      await _channel.invokeMethod<void>('status', {'status': status}).timeout(_statusTimeout);
    } catch (_) {
      // 保活只是锦上添花，失败（含超时）不打断对话
    }
  }

  /// 撤掉保活和悬浮图标（一轮对话结束时）。
  static Future<void> stop() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('stop').timeout(_stopTimeout);
    } catch (_) {}
  }
}
