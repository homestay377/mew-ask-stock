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

  /// 直接设成目标可视根数（双指缩放用）。
  ///
  /// 用绝对值而不是增量：双指时两指间距会持续变化，
  /// 增量累加会放大误差，也容易因为某一帧抖动而跳变。
  void zoomTo(int target) {
    final nv = target.clamp(minVisible, math.max(minVisible, total)).toInt();
    if (nv == visible) return;
    // 以右端为锚点：看盘时最新价保持不动更符合直觉
    final rightEdge = start + visible;
    visible = nv;
    start = (rightEdge - visible).clamp(0, math.max(0, total - visible));
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

  /// 当前按在屏上的指针位置。PointerMoveEvent 没有 pointerCount，只能自己数。
  final Map<int, Offset> _pointers = <int, Offset>{};

  /// 双指缩放基准：开始双指那一刻的两指间距与当时的可视根数。
  double _pinchStartDist = 0;
  int _pinchStartVisible = 0;

  /// 本次手势是否经历过多指。多指之后剩下一根手指时不再当作拖动，
  /// 否则会因为缺少基准点而跳一下。
  bool _multiTouchSession = false;
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
        _resetPinch();
        _reset();
      },
      child: widget.child,
    );
  }

  /// 两指之间的直线距离。
  double _distanceBetweenPointers() {
    if (_pointers.length < 2) return 0;
    final pts = _pointers.values.toList();
    return (pts[0] - pts[1]).distance;
  }

  /// 双指基准清零。少一根手指后，下次重新按第二指时会重新建立。
  void _resetPinch() {
    _pinchStartDist = 0;
    _pinchStartVisible = 0;
  }

  void _reset() {
    _multiTouchSession = false;
    _downPos = null;
    _lastPos = null;
    _dragging = false;
    _longPressed = false;
    _lockAxis = false;
  }

  void _onDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;

    // ★ 第二根手指按下，就是双指缩放的起点。
    //   必须在这里建立基准：touchstart/pointerdown 不会因为「变成两指」再触发一次，
    //   Eta 的原实现把基准放在 `touches.length === 2` 的 down 分支里，
    //   那个分支几乎永不成立，pinchDist 一直是 0 或残留值，
    //   于是 ratio 用错的基准算，方向看起来就反了。
    if (_pointers.length == 2) {
      _multiTouchSession = true;
      _pinchStartDist = _distanceBetweenPointers();
      _pinchStartVisible = widget.viewport.visible;
      _dragging = true;
      _lockAxis = true;
      widget.onCrosshair(-1);
      return;
    }
    if (_pointers.length > 2) return;

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
    _pointers[e.pointer] = e.localPosition;

    // 双指：只按两指间距的比例缩放，不做平移。
    if (_pointers.length >= 2) {
      if (_pinchStartDist <= 0) return;
      final d = _distanceBetweenPointers();
      if (d <= 0) return;
      // 拉开（d 变大）→ ratio > 1 → 可视根数变多？
      // 不是：visible 是「可视根数」，根数越少每根越宽 = 放大。
      // 所以拉开应当让 visible 变小，用初始间距 / 当前间距。
      final target = (_pinchStartVisible * (_pinchStartDist / d)).round();
      widget.viewport.zoomTo(target);
      return;
    }

    if (_multiTouchSession) return;

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
    _resetPinch();
    // 所有手指都离开了，才结束这次手势
    final allUp = _pointers.isEmpty;
    if (!allUp) {
      // 还剩手指：忽略后续移动，等全部抬起
      _dragging = false;
      return;
    }
    // 双指手势结束时不该再判定成「轻点选中」
    final wasMulti = _multiTouchSession;
    _multiTouchSession = false;
    final wasLong = _longPressed;
    final wasDrag = _dragging;
    final down = _downPos;
    _reset();

    if (wasLong) {
      widget.onLongPressRelease(_indexAt(e.localPosition));
      return;
    }
    if (wasMulti || wasDrag || down == null) return;

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
