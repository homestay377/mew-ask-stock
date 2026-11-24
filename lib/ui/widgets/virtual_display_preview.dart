import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:mewhub/core/i18n.dart';
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
    this.height = 360,
    this.enabled = true,
  });

  final VirtualDisplayChannel? channel;
  final int intervalMs;

  /// 预览高度；`null` 表示撑满父级（放进 Expanded 时用）。宽度按手机比例算。
  final double? height;
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
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: _png == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error ?? t('读取画面…', 'Loading frame…'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                ),
              ),
            )
          : Image.memory(_png!, gaplessPlayback: true, fit: BoxFit.contain),
    );

    final sized = Center(
      child: AspectRatio(aspectRatio: 9 / 19.5, child: body),
    );
    final h = widget.height;
    return h == null ? sized : SizedBox(height: h, child: sized);
  }
}

/// 底部弹出「看虚拟屏」：聊天里随时瞄一眼 AI 正在操作的那块屏。
Future<void> showVirtualDisplaySheet(BuildContext context, {VirtualDisplayChannel? channel}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      final h = MediaQuery.of(ctx).size.height;
      return SizedBox(
        height: h * 0.72,
        child: Column(
          children: [
            ListTile(
              dense: true,
              title: Text(t('虚拟屏（AI 正在操作的那块）', 'Virtual display (what the AI sees)')),
              subtitle: Text(
                t('只读预览；要操作请让 AI 做', 'Read-only preview; ask the AI to act'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
            Expanded(child: VirtualDisplayPreview(channel: channel)),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}
