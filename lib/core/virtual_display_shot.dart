import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

/// 虚拟屏截图要不要交给模型，以及画面的宽高比。
///
/// 同花顺这类界面，OCR 只能给出"一堆文字 + 坐标"，而多模态模型直接看图更准也更省 token：
/// 它自己就能认出按钮、列表项、被选中的项。所以：
///
/// - 生成开始时由 [ChatController] 按当前模型能力置 [wanted]（不支持视觉的模型就不截图，
///   省掉一次 PNG 编码）；
/// - 读屏成功时工具把截图落到缓存文件，[offer] 记下来；
/// - 下一轮请求前 [take] 取走，作为一条**临时**的 user 消息带上图片——
///   这条消息只进当次请求，不写进会话、不在界面上冒泡。
class VirtualDisplayShot {
  VirtualDisplayShot._();

  static bool wanted = false;
  static String? _last;

  /// 最近一帧的 高/宽。悬浮窗要按真实比例显示，否则 `cover` 会把上下裁掉。
  static final ValueNotifier<double?> aspect = ValueNotifier<double?>(null);

  static void offer(String path) {
    if (wanted) _last = path;
  }

  static String? take() {
    final p = _last;
    _last = null;
    return p;
  }

  /// 从 PNG 头里读宽高（IHDR 固定在第 16~24 字节，大端），不用解码整张图。
  static Size? sizeOf(Uint8List bytes) {
    if (bytes.length < 24) return null;
    if (bytes[0] != 0x89 || bytes[1] != 0x50) return null;
    final w = (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
    final h = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
    if (w <= 0 || h <= 0) return null;
    return Size(w.toDouble(), h.toDouble());
  }

  /// 会话被切走/取消时清掉，避免把上一轮的图带到下一次。
  static void reset() {
    _last = null;
    wanted = false;
  }
}
