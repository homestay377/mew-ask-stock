import 'package:flutter/material.dart';

import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/core/virtual_display_overlay_state.dart';
import 'package:mewhub/tools/virtual_display_channel.dart';
import 'package:mewhub/ui/widgets/virtual_display_preview.dart';

/// 虚拟屏的悬浮窗：一小块实时画面飘在界面上。
///
/// 交互照 Mika 的来：
/// - **可以拖到任意位置**（拖动不会误触放大）；
/// - **点一下放大**，放大时背景变暗、点画面以外任何地方就缩回去；
/// - 右上角 × 直接关掉（关掉后不会自己再冒出来，除非 AI 又动那块屏）。
class VirtualDisplayOverlay extends StatefulWidget {
  const VirtualDisplayOverlay({super.key, this.channel});

  final VirtualDisplayChannel? channel;

  @override
  State<VirtualDisplayOverlay> createState() => _VirtualDisplayOverlayState();
}

class _VirtualDisplayOverlayState extends State<VirtualDisplayOverlay> {
  static const double _thumbW = 108;
  static const double _thumbH = 192;
  static const double _edge = 10;

  bool _expanded = false;
  Offset? _pos;

  void _drag(Size size, Offset delta) {
    final cur = _pos ?? _defaultPos(size);
    setState(() {
      _pos = Offset(
        (cur.dx + delta.dx).clamp(_edge, size.width - _thumbW - _edge).toDouble(),
        (cur.dy + delta.dy).clamp(_edge, size.height - _thumbH - _edge).toDouble(),
      );
    });
  }

  Offset _defaultPos(Size size) => Offset(size.width - _thumbW - _edge, size.height * 0.18);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: VirtualDisplayOverlayState.visible,
      builder: (ctx, on, _) {
        if (!on) return const SizedBox.shrink();
        final size = MediaQuery.of(ctx).size;
        return _expanded ? _expandedLayer(size) : _thumbLayer(size);
      },
    );
  }

  Widget _thumbLayer(Size size) {
    final pos = _pos ?? _defaultPos(size);
    return Stack(
      children: [
        Positioned(
          left: pos.dx.clamp(_edge, size.width - _thumbW - _edge).toDouble(),
          top: pos.dy.clamp(_edge, size.height - _thumbH - _edge).toDouble(),
          child: GestureDetector(
            onTap: () => setState(() => _expanded = true),
            onPanUpdate: (d) => _drag(size, d.delta),
            child: Stack(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 14, offset: Offset(0, 4))],
                  ),
                  child: VirtualDisplayPreview(
                    channel: widget.channel,
                    width: _thumbW,
                    height: _thumbH,
                    fit: BoxFit.cover,
                    radius: 16,
                  ),
                ),
                Positioned(top: 2, right: 2, child: _closeButton()),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _expandedLayer(Size size) {
    return Stack(
      children: [
        // 点画面以外任何地方都会缩回去
        Positioned.fill(
          child: GestureDetector(
            onTap: () => setState(() => _expanded = false),
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.62)),
          ),
        ),
        Center(
          child: GestureDetector(
            onTap: () {}, // 点画面本身不缩回
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t('虚拟屏（AI 正在操作）', 'Virtual display (the AI is on it)'),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                const SizedBox(height: 8),
                VirtualDisplayPreview(channel: widget.channel, height: size.height * 0.62),
              ],
            ),
          ),
        ),
        Positioned(top: 12, right: 12, child: SafeArea(child: _closeButton(onDark: true))),
      ],
    );
  }

  Widget _closeButton({bool onDark = false}) {
    return GestureDetector(
      onTap: () {
        setState(() => _expanded = false);
        VirtualDisplayOverlayState.hide();
      },
      child: Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: onDark ? Colors.black45 : Colors.black.withValues(alpha: 0.45),
        ),
        child: Icon(Icons.close_rounded, size: onDark ? 20 : 13, color: Colors.white),
      ),
    );
  }
}
