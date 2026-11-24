import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/core/virtual_display_shot.dart';
import 'package:mewhub/tools/virtual_display_channel.dart';

/// 虚拟屏的实时画面。
///
/// 为什么要有它：AI 能读到那块屏上的文字，但**人看不见**——用户只能对着 AI 的描述猜
/// "它看的到底是不是我要的那一页"。这里按 [intervalMs] 轮询一次截图（原生侧已经把短边
/// 缩到 720，编码成本可控），只当预览，不接受点击。
class VirtualDisplayPreview extends StatefulWidget {
  const VirtualDisplayPreview({
    super.key,
    this.channel,
    this.intervalMs = 1200,
    this.height,
    this.width,
    this.fit = BoxFit.contain,
    this.radius = 12,
    this.enabled = true,
  });

  final VirtualDisplayChannel? channel;
  final int intervalMs;

  /// 高度；`null` 表示按父级撑满（放进 Expanded 时用），或只给 [width] 时按比例算。
  final double? height;

  /// 宽度。给了宽高就直接铺满这个框（缩略图用，配 [BoxFit.cover]）。
  final double? width;

  /// 画面填充方式：大图 `contain`（不裁），缩略图 `cover`（不留黑边）。
  final BoxFit fit;
  final double radius;
  final bool enabled;

  @override
  State<VirtualDisplayPreview> createState() => _VirtualDisplayPreviewState();
}

class _VirtualDisplayPreviewState extends State<VirtualDisplayPreview> {
  late final VirtualDisplayChannel _ch = widget.channel ?? VirtualDisplayChannel();
  Timer? _timer;
  Uint8List? _png;
  String? _error;
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _start() {
    _read();
    _timer?.cancel();
    _timer = Timer.periodic(Duration(milliseconds: widget.intervalMs), (_) => _read());
  }

  Future<void> _read() async {
    if (_reading) return;
    _reading = true;
    try {
      final png = await _ch.screenshot();
      if (!mounted) return;
      setState(() {
        if (png != null) {
          _png = png;
          _error = null;
          // 记下真实宽高比：悬浮窗要按这个比例显示，否则 cover 会把整屏裁掉上下
          final size = VirtualDisplayShot.sizeOf(png);
          if (size != null) VirtualDisplayShot.aspect.value = size.height / size.width;
        } else if (_png == null) {
          _error = t('还没有画面：先让 AI 打开一个 App', 'No frame yet: open an app first');
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _reading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: _png == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _error ?? t('读取画面…', 'Loading frame…'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
                ),
              ),
            )
          : Image.memory(_png!, gaplessPlayback: true, fit: widget.fit),
    );

    final w = widget.width;
    final h = widget.height;
    if (w != null && h != null) return SizedBox(width: w, height: h, child: body);
    if (w != null) {
      // 只给宽度：高度按真实画面比例走（悬浮窗用这个，整屏都看得见，不再裁上下）
      return SizedBox(width: w, child: body);
    }
    final byAspect = Center(
      child: AspectRatio(aspectRatio: 9 / 19.5, child: body),
    );
    return h == null ? byAspect : SizedBox(height: h, child: byAspect);
  }
}
