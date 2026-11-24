/// 虚拟屏截图要不要交给模型。
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

  static void offer(String path) {
    if (wanted) _last = path;
  }

  static String? take() {
    final p = _last;
    _last = null;
    return p;
  }

  /// 会话被切走/取消时清掉，避免把上一轮的图带到下一次。
  static void reset() {
    _last = null;
    wanted = false;
  }
}
