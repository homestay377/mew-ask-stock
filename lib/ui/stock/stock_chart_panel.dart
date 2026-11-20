/// 对话页底部的 K 线面板：可展开 / 可缩回，展开时可拖动调整高度。
///
/// 挂载点：`ChatPage` 底部 `Column` 里，`Composer` 上方。
/// 放进 dock 测量的范围内，消息列表会自动让出空间。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../stock/chanlun.dart';
import '../../stock/stock_source.dart';

/// 面板状态：选中的代码、周期、是否展开。
class StockPanelState extends ChangeNotifier {
  StockPanelState({String symbol = 'sz300274', String period = 'day'}) : _symbol = symbol, _period = period;

  String _symbol;
  String _period;
  bool _expanded = false;

  /// 展开后的高度比例（占可用高度的比例）。
  double _fraction = 0.42;

  String get symbol => _symbol;
  String get period => _period;
  bool get expanded => _expanded;
  double get fraction => _fraction;

  void expand() {
    if (_expanded) return;
    _expanded = true;
    notifyListeners();
  }

  void collapse() {
    if (!_expanded) return;
    _expanded = false;
    notifyListeners();
  }

  void toggle() => _expanded ? collapse() : expand();

  void setSymbol(String v) {
    final s = v.trim();
    if (s.isEmpty || s == _symbol) return;
    _symbol = s;
    notifyListeners();
  }

  void setPeriod(String v) {
    if (v == _period) return;
    _period = v;
    notifyListeners();
  }

  void setFraction(double v) {
    final clamped = v.clamp(0.18, 0.82);
    if ((clamped - _fraction).abs() < 0.005) return;
    _fraction = clamped;
    notifyListeners();
  }
}

/// 全局单例：一个会话一个面板状态即可。
final stockPanel = StockPanelState();

const _periodLabels = <String, String>{'day': '日', 'week': '周', 'month': '月', 'm60': '60分', 'm30': '30分', 'm15': '15分'};

class StockChartPanel extends StatefulWidget {
  const StockChartPanel({super.key, required this.state, required this.source, this.maxHeight = 360});

  final StockPanelState state;

  /// 与工具层共用的数据源；传 null 时面板自建一个。
  final StockSource? source;
  final double maxHeight;

  @override
  State<StockChartPanel> createState() => _StockChartPanelState();
}

class _StockChartPanelState extends State<StockChartPanel> {
  StockSource? _ownSource;
  KlineSeries? _series;
  ChanResult? _chan;
  String? _error;
  bool _loading = false;

  StockSource get _src => widget.source ?? (_ownSource ??= StockSource());

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onStateChanged);
    if (widget.state.expanded) _load();
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    _ownSource?.close();
    super.dispose();
  }

  String _lastKey = '';

  void _onStateChanged() {
    // 展开 / 换股 / 换周期时才重新取数；拖动高度不触发。
    if (!mounted) return;
    if (widget.state.expanded) {
      final key = '${widget.state.symbol}|${widget.state.period}';
      if (key != _lastKey) _load();
    }
    setState(() {});
  }

  Future<void> _load() async {
    final key = '${widget.state.symbol}|${widget.state.period}';
    _lastKey = key;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await _src.kline(widget.state.symbol, period: widget.state.period);
      if (!mounted || '${widget.state.symbol}|${widget.state.period}' != key) return;
      setState(() {
        _series = s;
        _chan = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // 收起态：一条紧凑的胶囊，点击展开。
    if (!widget.state.expanded) {
      return _CollapsedBar(state: widget.state, onTap: widget.state.expand);
    }

    final height = math.min(widget.maxHeight, MediaQuery.sizeOf(context).height * 0.5);

    return Container(
      height: height,
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _PanelHeader(state: widget.state, onCollapse: widget.state.collapse),
          Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
          Expanded(child: _buildBody(scheme)),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading) {
      return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)));
    }
    final err = _error;
    if (err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            err,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.error, fontSize: 12),
          ),
        ),
      );
    }
    final s = _series;
    if (s == null || s.bars.isEmpty) {
      return Center(
        child: Text('暂无数据', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
      );
    }
    return _KlineCanvas(series: s, chan: _chan, scheme: scheme);
  }
}

/// 收起态胶囊：显示代码 + 现价 + 涨跌，点击展开。
class _CollapsedBar extends StatelessWidget {
  const _CollapsedBar({required this.state, required this.onTap});

  final StockPanelState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      child: Material(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              children: [
                Icon(Icons.candlestick_chart_rounded, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  state.symbol.replaceFirst(RegExp(r'^(sh|sz|bj)'), '').toUpperCase(),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface),
                ),
                const SizedBox(width: 8),
                Text(
                  _periodLabels[state.period] ?? state.period,
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
                const Spacer(),
                Text('展开 K 线', style: TextStyle(fontSize: 12, color: scheme.primary)),
                const SizedBox(width: 4),
                Icon(Icons.keyboard_arrow_up_rounded, size: 18, color: scheme.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 面板头部：代码、周期切换、收起。
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.state, required this.onCollapse});

  final StockPanelState state;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final e in _periodLabels.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: _Chip(
                        label: e.value,
                        selected: state.period == e.key,
                        onTap: () => state.setPeriod(e.key),
                      ),
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: scheme.onSurfaceVariant),
            onPressed: onCollapse,
            tooltip: '收起',
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// K 线画布：蜡烛 + 成交量 + 均线 + 缠论中枢框。
class _KlineCanvas extends StatelessWidget {
  const _KlineCanvas({required this.series, required this.chan, required this.scheme});

  final KlineSeries series;
  final ChanResult? chan;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final bars = series.bars;
    final show = bars.length > 120 ? bars.sublist(bars.length - 120) : bars;
    return LayoutBuilder(
      builder: (context, c) {
        return CustomPaint(
          size: Size(c.maxWidth, c.maxHeight),
          painter: _KlinePainter(
            bars: show,
            offset: bars.length - show.length,
            chan: chan,
            up: const Color(0xFFE5484D),
            down: const Color(0xFF30A46C),
            grid: scheme.outlineVariant.withValues(alpha: 0.35),
            text: scheme.onSurfaceVariant,
          ),
        );
      },
    );
  }
}

class _KlinePainter extends CustomPainter {
  _KlinePainter({
    required this.bars,
    required this.offset,
    required this.chan,
    required this.up,
    required this.down,
    required this.grid,
    required this.text,
  });

  final List<Bar> bars;
  final int offset;
  final ChanResult? chan;
  final Color up;
  final Color down;
  final Color grid;
  final Color text;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;

    const padLeft = 4.0;
    const padRight = 44.0;
    const padTop = 6.0;
    const volRatio = 0.22;

    final chartW = size.width - padLeft - padRight;
    final chartH = size.height * (1 - volRatio) - padTop - 4;
    final volH = size.height * volRatio - 4;
    if (chartW <= 0 || chartH <= 0) return;

    var minL = double.infinity;
    var maxH = -double.infinity;
    var maxV = 0.0;
    for (final b in bars) {
      if (b.l < minL) minL = b.l;
      if (b.h > maxH) maxH = b.h;
      if (b.v > maxV) maxV = b.v;
    }
    final pad = (maxH - minL) * 0.06;
    minL -= pad;
    maxH += pad;
    final span = (maxH - minL) == 0 ? 1.0 : maxH - minL;

    double yOf(double price) => padTop + (maxH - price) / span * chartH;

    // 网格 + 右侧价格刻度
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 0.6;
    final textStyle = TextStyle(color: text, fontSize: 9);
    for (var i = 0; i <= 4; i++) {
      final y = padTop + chartH * i / 4;
      canvas.drawLine(Offset(padLeft, y), Offset(padLeft + chartW, y), gridPaint);
      final price = maxH - span * i / 4;
      final tp = TextPainter(
        text: TextSpan(text: price.toStringAsFixed(2), style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(padLeft + chartW + 4, y - tp.height / 2));
    }

    final step = chartW / bars.length;
    final bodyW = math.max(1.0, step * 0.62);

    // 缠论中枢框（画在蜡烛下面）
    final ch = chan;
    if (ch != null) {
      for (final box in ch.boxes) {
        final s = box.s - offset;
        final e = box.e - offset;
        if (e < 0 || s >= bars.length) continue;
        final x1 = padLeft + math.max(0, s) * step;
        final x2 = padLeft + math.min(bars.length - 1, e) * step + step;
        final y1 = yOf(box.zg);
        final y2 = yOf(box.zd);
        final color = box.tag == '红' ? up : down;
        canvas.drawRect(
          Rect.fromLTRB(x1, y1, x2, y2),
          Paint()
            ..color = color.withValues(alpha: 0.10)
            ..style = PaintingStyle.fill,
        );
        canvas.drawRect(
          Rect.fromLTRB(x1, y1, x2, y2),
          Paint()
            ..color = color.withValues(alpha: 0.55)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
    }

    // 蜡烛 + 成交量
    final wickPaint = Paint()..strokeWidth = 1;
    for (var i = 0; i < bars.length; i++) {
      final b = bars[i];
      final cx = padLeft + (i + 0.5) * step;
      final isUp = b.c >= b.o;
      final color = isUp ? up : down;

      wickPaint.color = color;
      canvas.drawLine(Offset(cx, yOf(b.h)), Offset(cx, yOf(b.l)), wickPaint);

      final top = yOf(math.max(b.o, b.c));
      final bot = yOf(math.min(b.o, b.c));
      canvas.drawRect(
        Rect.fromLTRB(cx - bodyW / 2, top, cx + bodyW / 2, math.max(bot, top + 0.8)),
        Paint()..color = color,
      );

      if (maxV > 0) {
        final vh = b.v / maxV * volH;
        final vy = size.height - 2 - vh;
        canvas.drawRect(
          Rect.fromLTRB(cx - bodyW / 2, vy, cx + bodyW / 2, size.height - 2),
          Paint()..color = color.withValues(alpha: 0.55),
        );
      }
    }

    // 最新价横线
    final lastClose = bars.last.c;
    final ly = yOf(lastClose);
    canvas.drawLine(
      Offset(padLeft, ly),
      Offset(padLeft + chartW, ly),
      Paint()
        ..color = (bars.last.c >= bars.last.o ? up : down).withValues(alpha: 0.7)
        ..strokeWidth = 0.8,
    );
  }

  @override
  bool shouldRepaint(_KlinePainter old) => old.bars != bars || old.chan != chan || old.offset != offset;
}
