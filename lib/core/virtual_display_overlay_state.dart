import 'package:flutter/foundation.dart';

/// 虚拟屏悬浮窗的开关。
///
/// 谁开它：AI 真的在那块屏上打开了 App 时（工具层调 [show]），因为这时候用户才需要
/// "看着它点"。谁关它：用户点悬浮窗上的 ×，或者菜单里再点一次「看虚拟屏」。
class VirtualDisplayOverlayState {
  VirtualDisplayOverlayState._();

  static final ValueNotifier<bool> visible = ValueNotifier<bool>(false);

  static void show() {
    if (!visible.value) visible.value = true;
  }

  static void hide() => visible.value = false;

  static void toggle() => visible.value = !visible.value;
}
