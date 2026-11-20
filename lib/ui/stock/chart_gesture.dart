/// K 线画布的手势内核：缩放、平移、十字光标、点选。
///
/// 与 Eta 的 `chart.js` 参数对齐：
///  - 长按 300ms 出十字
///  - 位移超过 14px 才判定方向（手指微抖不算拖动）
///  - 垂直缩放灵敏度 150（越小越快）
///  - 可视范围 8 根 ~ 全量
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 画布视口状态：可视根数与起点。
class ChartViewport extends ChangeNotifier {
  ChartViewport();

  /// 可视 K 线数。
  int visible = 100;

  /// 可视区最左侧那根的索引。
  int start = 0;

  /// 全量根数。
  int total = 0;

  static const int minVisible = 8;
  static const longPressMs = 300;
  static const axisLockPx = 14.0;
  static const zoomK = 150.0;

  /// 换数据时重置到「看最新」。
  void reset(int totalBars) {
    total = totalBars;
    visible = math.min(100, math.max(minVisible, totalBars));
    start = math.max(0, totalBars - visible);
    notifyListeners();
  }

  /// 分时：全量显示，不允许缩放（与 Eta 一致）。
  void showAll(int count) {
    total = count;
    visible = math.max(1, count);
    start = 0;
    notifyListeners();
  }

  void zoom(double factor) {
    final nv = (visible * factor).round().clamp(minVisible, math.max(minVisible, total)).toInt();
    if (nv == visible) return;
    // 以右端为锚点缩放：看盘时更符合直觉（最新价不动）
    final rightEdge = start + visible;
    visible = nv;
    start = (rightEdge - visible).clamp(0, math.max(0, total - visible));
    notifyListeners();
  }

  void pan(int deltaBars) {
    final ns = (start + deltaBars).clamp(0, math.max(0, total - visible)).toInt();
    if (ns == start) return;
    start = ns;
    notifyListeners();
  }

  /// 把索引限制在可视区内。
  int clampIndex(int i) => i.clamp(0, math.max(0, total - 1));
}

/// 十字光标状态。
class CrosshairState {
  CrosshairState();

  /// 当前指向的 K 线索引；-1 表示没有。
  int index = -1;

  /// 是否正在长按（决定要不要画竖线）。
  bool active = false;

  void clear() {
    index = -1;
    active = false;
  }
}

/// 包在画布外面的交互层。
class ChartGestureLayer extends StatefulWidget {
  const ChartGestureLayer({
    super.key,
    required this.viewport,
    required this.child,
    required this.onCrosshair,
    required this.onTapBar,
    required this.onLongPressRelease,
  });

  final ChartViewport viewport;
  final Widget child;

  /// 十字光标移动时回调索引（-1 表示移出）。
  final void Function(int index) onCrosshair;

  /// 轻点某一根。
  final void Function(int index) onTapBar;

  /// 长按结束（抬手）时回调，用于显示「问这根」。
  final void Function(int index) onLongPressRelease;

  @override
  State<ChartGestureLayer> createState() => _ChartGestureLayerState();
}

class _ChartGestureLayerState extends State<ChartGestureLayer> {
  Offset? _downPos;
  Offset? _lastPos;

  /// 当前按在屏上的指针数。PointerMoveEvent 没有 pointerCount，只能自己数。
  final Set<int> _pointers = <int>{};
  bool _dragging = false;
  bool _longPressed = false;
  bool _lockAxis = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: (e) {
        _pointers.remove(e.pointer);
        _reset();
      },
      child: widget.child,
    );
  }

  void _reset() {
    _downPos = null;
    _lastPos = null;
    _dragging = false;
    _longPressed = false;
    _lockAxis = false;
  }

  void _onDown(PointerDownEvent e) {
    _pointers.add(e.pointer);
    _downPos = e.localPosition;
    _lastPos = e.localPosition;
    _dragging = false;
    _longPressed = false;
    _lockAxis = false;

    // 长按计时
    Future.delayed(const Duration(milliseconds: ChartViewport.longPressMs), () {
      if (!mounted || _dragging || _downPos == null) return;
      _longPressed = true;
      widget.onCrosshair(_indexAt(e.localPosition));
    });
  }

  void _onMove(PointerMoveEvent e) {
    final last = _lastPos;
    if (last == null) return;
    final dx = e.localPosition.dx - last.dx;
    final dy = e.localPosition.dy - last.dy;
    _lastPos = e.localPosition;

    final down = _downPos;
    if (down != null && !_lockAxis) {
      final totalDx = (e.localPosition.dx - down.dx).abs();
      final totalDy = (e.localPosition.dy - down.dy).abs();
      if (totalDx > ChartViewport.axisLockPx || totalDy > ChartViewport.axisLockPx) {
        _lockAxis = true;
        _dragging = true;
        // 开始拖动就取消十字
        widget.onCrosshair(-1);
      } else {
        return;
      }
    }
    if (!_dragging) return;

    final vp = widget.viewport;
    if (_pointers.length >= 2) {
      // 双指缩放
      final zoomFactor = math.exp(-dx / 60.0);
      vp.zoom(1 / zoomFactor);
      return;
    }

    // 水平拖 → 平移；垂直拖 → 缩放
    if (dx.abs() > dy.abs() * 0.7) {
      final barW = _barWidth;
      if (barW > 0) vp.pan((-dx / barW).round());
    } else {
      vp.zoom(math.exp(dy / ChartViewport.zoomK));
    }
  }

  void _onUp(PointerUpEvent e) {
    _pointers.remove(e.pointer);
    final wasLong = _longPressed;
    final wasDrag = _dragging;
    final down = _downPos;
    _reset();

    if (wasLong) {
      widget.onLongPressRelease(_indexAt(e.localPosition));
      return;
    }
    if (wasDrag || down == null) return;

    // 轻点
    final moved = (e.localPosition - down).distance;
    if (moved < ChartViewport.axisLockPx) {
      widget.onTapBar(_indexAt(e.localPosition));
    }
  }

  /// 每根 K 线的宽度由画布反推；这里用视口和渲染宽度的约定比例。
  double get _barWidth {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return 6;
    final w = box.size.width - 2 - 42; // 与画笔的 padLeft / padRight 保持一致
    return w <= 0 ? 6 : w / widget.viewport.visible;
  }

  int _indexAt(Offset pos) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return -1;
    const padLeft = 2.0;
    const padRight = 42.0;
    final w = box.size.width - padLeft - padRight;
    if (w <= 0) return -1;
    final step = w / widget.viewport.visible;
    if (step <= 0) return -1;
    final rel = ((pos.dx - padLeft) / step).floor();
    if (rel < 0 || rel >= widget.viewport.visible) return -1;
    return widget.viewport.start + rel;
  }
}
