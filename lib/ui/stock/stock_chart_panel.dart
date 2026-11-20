/// 对话页底部的 K 线面板：可展开 / 可缩回，展开时占内容区一部分高度。
///
/// 功能对齐 Eta 问股的 K 线面板：
///  - 级别切换：周 / 日 / 60 / 30 / 15 / 5
///  - 主图指标：MA、BOLL、缠论中枢、空心 K
///  - 副图指标：成交量、MACD、KDJ、RSI（互斥显示一个）
///
/// 交互形式保持不变：收起态是一行胶囊，点击展开；展开后可再点收起。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../stock/chanlun.dart';
import '../../stock/indicators.dart';
import '../../stock/stock_source.dart';

/// 主图指标键，顺序与 Eta 的 `MAIN_IND_KEYS` 一致。
const mainIndKeys = ['MA', 'BOLL', 'CHAN', 'HOLLOW'];

/// 副图指标键，顺序与 Eta 的 `SUB_IND_KEYS` 一致。
const subIndKeys = ['VOL', 'MACD', 'KDJ', 'RSI'];

const _periodLabels = <String, String>{'week': '周', 'day': '日', 'm60': '60', 'm30': '30', 'm15': '15', 'm5': '5'};

String indLabel(String key, {bool hollow = false}) => switch (key) {
  'MA' => 'MA',
  'BOLL' => 'BOLL',
  'CHAN' => '缠论',
  'HOLLOW' => hollow ? '空心K' : '实心K',
  'VOL' => '成交量',
  _ => key,
};

/// 面板状态：级别、指标开关、是否展开。
class StockPanelState extends ChangeNotifier {
  StockPanelState({this._symbol = 'sz300274', this._period = 'day'});

  String _symbol;
  String _period;
  bool _expanded = false;

  /// 主图指标开关。MA 默认开。
  final Map<String, bool> mainOn = {'MA': true, 'BOLL': false, 'CHAN': true, 'HOLLOW': false};

  /// 副图指标：互斥，只能选一个。
  String _subInd = 'VOL';

  String get symbol => _symbol;
  String get period => _period;
  bool get expanded => _expanded;
  String get subInd => _subInd;

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

  void toggleMain(String key) {
    mainOn[key] = !(mainOn[key] ?? false);
    notifyListeners();
  }

  void setSub(String key) {
    if (_subInd == key) return;
    _subInd = key;
    notifyListeners();
  }

  bool get showMA => mainOn['MA'] ?? false;
  bool get showBoll => mainOn['BOLL'] ?? false;
  bool get showChan => mainOn['CHAN'] ?? false;
  bool get hollow => mainOn['HOLLOW'] ?? false;
}

/// 全局单例：会话之间共用一个面板。
final stockPanel = StockPanelState();

class StockChartPanel extends StatefulWidget {
  const StockChartPanel({super.key, required this.state, this.source, this.maxHeight = 380});

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
  String _lastKey = '';

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

  void _onStateChanged() {
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
      ChanResult? ch;
      if (widget.state.showChan) {
        ch = Chanlun.analyze(s.bars, await _formula());
      }
      setState(() {
        _series = s;
        _chan = ch;
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

  /// 缠论开关键变化时，按需补算或丢弃中枢结果。
  void _syncChan() {
    final s = _series;
    if (s == null) return;
    if (!widget.state.showChan) {
      if (_chan != null) setState(() => _chan = null);
      return;
    }
    if (_chan == null) {
      _formula().then((f) {
        if (!mounted) return;
        setState(() => _chan = Chanlun.analyze(s.bars, f));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (!widget.state.expanded) {
      return _CollapsedBar(state: widget.state, onTap: widget.state.expand);
    }

    final height = math.min(widget.maxHeight, MediaQuery.sizeOf(context).height * 0.54);

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
          _PeriodRow(state: widget.state, onCollapse: widget.state.collapse),
          Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.35)),
          _IndBar(state: widget.state, onChange: _syncChan),
          Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.35)),
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
    return _KlineCanvas(
      series: s,
      chan: _chan,
      subInd: widget.state.subInd,
      showMA: widget.state.showMA,
      showBoll: widget.state.showBoll,
      hollow: widget.state.hollow,
      scheme: scheme,
    );
  }
}

String? _formulaText;

Future<String> _formula() async {
  final c = _formulaText;
  if (c != null) return c;
  final t = await _FormulaAsset.load();
  _formulaText = t;
  return t;
}

/// 公式原文加载器（放在独立类里，方便测试时替换）。
class _FormulaAsset {
  static Future<String> load() async => formulaLoader();

  /// 由 `stock_tools.dart` 在启动时注入；未注入时返回空公式（不画中枢）。
  static Future<String> Function() formulaLoader = () async => '';
}

/// 允许外部注入公式加载方式（App 启动时设为 rootBundle 读取）。
void setStockFormulaLoader(Future<String> Function() loader) {
  _FormulaAsset.formulaLoader = loader;
  _formulaText = null;
}

/// 收起态胶囊。
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

/// 级别行：周期切换 + 收起按钮。
class _PeriodRow extends StatelessWidget {
  const _PeriodRow({required this.state, required this.onCollapse});

  final StockPanelState state;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final e in _periodLabels.entries)
                    _Chip(label: e.value, selected: state.period == e.key, onTap: () => state.setPeriod(e.key)),
                ],
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            icon: Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: scheme.onSurfaceVariant),
            onPressed: onCollapse,
            tooltip: '收起',
          ),
        ],
      ),
    );
  }
}

/// 指标横条：主图一排、副图一排。
class _IndBar extends StatelessWidget {
  const _IndBar({required this.state, required this.onChange});

  final StockPanelState state;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Text('主', style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
                const SizedBox(width: 6),
                for (final k in mainIndKeys)
                  _Chip(
                    label: indLabel(k, hollow: state.hollow),
                    selected: state.mainOn[k] ?? false,
                    onTap: () {
                      state.toggleMain(k);
                      onChange();
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Text('副', style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
                const SizedBox(width: 6),
                for (final k in subIndKeys)
                  _Chip(label: indLabel(k), selected: state.subInd == k, onTap: () => state.setSub(k)),
              ],
            ),
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
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: selected ? scheme.primary.withValues(alpha: 0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// K 线画布：蜡烛 + 主图指标 + 副图指标 + 缠论中枢。
class _KlineCanvas extends StatelessWidget {
  const _KlineCanvas({
    required this.series,
    required this.chan,
    required this.subInd,
    required this.showMA,
    required this.showBoll,
    required this.hollow,
    required this.scheme,
  });

  final KlineSeries series;
  final ChanResult? chan;
  final String subInd;
  final bool showMA;
  final bool showBoll;
  final bool hollow;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final bars = series.bars;
    final show = bars.length > 120 ? bars.sublist(bars.length - 120) : bars;
    final offset = bars.length - show.length;

    return LayoutBuilder(
      builder: (context, c) {
        return CustomPaint(
          size: Size(c.maxWidth, c.maxHeight),
          painter: _KlinePainter(
            bars: show,
            allBars: bars,
            offset: offset,
            chan: chan,
            subInd: subInd,
            showMA: showMA,
            showBoll: showBoll,
            hollow: hollow,
            up: const Color(0xFFE5484D),
            down: const Color(0xFF30A46C),
            grid: scheme.outlineVariant.withValues(alpha: 0.35),
            text: scheme.onSurfaceVariant,
            maColors: const [Color(0xFFE8A33D), Color(0xFF4A8FE7), Color(0xFFB065D4)],
          ),
        );
      },
    );
  }
}

class _KlinePainter extends CustomPainter {
  _KlinePainter({
    required this.bars,
    required this.allBars,
    required this.offset,
    required this.chan,
    required this.subInd,
    required this.showMA,
    required this.showBoll,
    required this.hollow,
    required this.up,
    required this.down,
    required this.grid,
    required this.text,
    required this.maColors,
  });

  final List<Bar> bars;

  /// 全量 K 线：指标要在全量上算，再裁到可视范围，否则窗口左侧数值不准。
  final List<Bar> allBars;
  final int offset;
  final ChanResult? chan;
  final String subInd;
  final bool showMA;
  final bool showBoll;
  final bool hollow;
  final Color up;
  final Color down;
  final Color grid;
  final Color text;
  final List<Color> maColors;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;

    const padLeft = 2.0;
    const padRight = 42.0;
    const padTop = 4.0;

    // 副图占 26%，主图占其余。
    final subH = size.height * 0.26;
    final mainH = size.height - subH - padTop - 2;
    final chartW = size.width - padLeft - padRight;
    if (chartW <= 0 || mainH <= 0) return;

    var minL = double.infinity;
    var maxH = -double.infinity;
    var maxV = 0.0;
    for (final b in bars) {
      if (b.l < minL) minL = b.l;
      if (b.h > maxH) maxH = b.h;
      if (b.v > maxV) maxV = b.v;
    }

    // 布林带会超出高低点范围，把它算进纵轴。
    BollResult? bo;
    if (showBoll) {
      bo = boll(allBars);
      for (var i = offset; i < allBars.length; i++) {
        final u = bo.up[i];
        final l = bo.low[i];
        if (u != null && u > maxH) maxH = u;
        if (l != null && l < minL) minL = l;
      }
    }

    final pad = (maxH - minL) * 0.06;
    minL -= pad;
    maxH += pad;
    final span = (maxH - minL) == 0 ? 1.0 : maxH - minL;

    double yOf(double price) => padTop + (maxH - price) / span * mainH;

    // 网格 + 右侧刻度
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 0.6;
    final textStyle = TextStyle(color: text, fontSize: 8.5);
    for (var i = 0; i <= 3; i++) {
      final y = padTop + mainH * i / 3;
      canvas.drawLine(Offset(padLeft, y), Offset(padLeft + chartW, y), gridPaint);
      final price = maxH - span * i / 3;
      final tp = TextPainter(
        text: TextSpan(text: price.toStringAsFixed(2), style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(padLeft + chartW + 3, y - tp.height / 2));
    }

    final step = chartW / bars.length;
    final bodyW = math.max(1.0, step * 0.62);
    double xOf(int i) => padLeft + (i + 0.5) * step;

    // ---- 缠论中枢（最底层）----
    final ch = chan;
    if (ch != null) {
      for (final box in ch.boxes) {
        final s = box.s - offset;
        final e = box.e - offset;
        if (e < 0 || s >= bars.length) continue;
        final x1 = padLeft + math.max(0, s) * step;
        final x2 = padLeft + math.min(bars.length - 1, e) * step + step;
        final rect = Rect.fromLTRB(x1, yOf(box.zg), x2, yOf(box.zd));
        final color = box.tag == '红' ? up : down;
        canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.09));
        canvas.drawRect(
          rect,
          Paint()
            ..color = color.withValues(alpha: 0.5)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
    }

    // ---- 布林带 ----
    if (bo != null) {
      void drawLine(List<double?> vals, Color c) {
        final p = Path();
        var started = false;
        for (var i = 0; i < bars.length; i++) {
          final v = vals[offset + i];
          if (v == null) continue;
          final y = yOf(v);
          if (!started) {
            p.moveTo(xOf(i), y);
            started = true;
          } else {
            p.lineTo(xOf(i), y);
          }
        }
        if (started) {
          canvas.drawPath(
            p,
            Paint()
              ..color = c
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.9,
          );
        }
      }

      drawLine(bo.up, const Color(0xFF7A8FA6));
      drawLine(bo.mid, const Color(0xFF9AA6B2));
      drawLine(bo.low, const Color(0xFF7A8FA6));
    }

    // ---- 蜡烛 ----
    final wickPaint = Paint()..strokeWidth = 1;
    for (var i = 0; i < bars.length; i++) {
      final b = bars[i];
      final cx = xOf(i);
      final isUp = b.c >= b.o;
      final color = isUp ? up : down;

      wickPaint.color = color;
      canvas.drawLine(Offset(cx, yOf(b.h)), Offset(cx, yOf(b.l)), wickPaint);

      final top = yOf(math.max(b.o, b.c));
      final bot = yOf(math.min(b.o, b.c));
      final rect = Rect.fromLTRB(cx - bodyW / 2, top, cx + bodyW / 2, math.max(bot, top + 0.8));

      // 空心 K：上涨用描边，下跌仍实心（与 Eta 的 HOLLOW 口径一致）
      if (hollow && isUp && bodyW > 2.5) {
        canvas.drawRect(
          rect,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      } else {
        canvas.drawRect(rect, Paint()..color = color);
      }
    }

    // ---- MA ----
    if (showMA) {
      final ma = maSeries(allBars, [5, 10, 20]);
      final keys = ['MA5', 'MA10', 'MA20'];
      for (var k = 0; k < keys.length; k++) {
        final vals = ma[keys[k]]!;
        final p = Path();
        var started = false;
        for (var i = 0; i < bars.length; i++) {
          final v = vals[offset + i];
          if (v == null) continue;
          final y = yOf(v);
          if (!started) {
            p.moveTo(xOf(i), y);
            started = true;
          } else {
            p.lineTo(xOf(i), y);
          }
        }
        if (started) {
          canvas.drawPath(
            p,
            Paint()
              ..color = maColors[k].withValues(alpha: 0.9)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1,
          );
        }
      }
    }

    // ---- 最新价线 ----
    final ly = yOf(bars.last.c);
    canvas.drawLine(
      Offset(padLeft, ly),
      Offset(padLeft + chartW, ly),
      Paint()
        ..color = (bars.last.c >= bars.last.o ? up : down).withValues(alpha: 0.65)
        ..strokeWidth = 0.8,
    );

    // ---- 副图 ----
    _paintSub(canvas, size, chartW, padLeft, subH, maxV);
  }

  void _paintSub(Canvas canvas, Size size, double chartW, double padLeft, double subH, double maxV) {
    final top = size.height - subH;
    final step = chartW / bars.length;
    double xOf(int i) => padLeft + (i + 0.5) * step;

    // 副图与主图之间的分隔
    canvas.drawLine(
      Offset(padLeft, top),
      Offset(padLeft + chartW, top),
      Paint()
        ..color = grid
        ..strokeWidth = 0.6,
    );

    if (subInd == 'VOL') {
      final vma = volMaSeries(allBars, [5, 10]);
      for (var i = 0; i < bars.length; i++) {
        final b = bars[i];
        final h = maxV == 0 ? 0.0 : b.v / maxV * (subH - 6);
        final isUp = b.c >= b.o;
        canvas.drawRect(
          Rect.fromLTRB(xOf(i) - step * 0.31, size.height - 3 - h, xOf(i) + step * 0.31, size.height - 3),
          Paint()..color = (isUp ? up : down).withValues(alpha: 0.5),
        );
      }
      // 量均线
      for (var k = 0; k < 2; k++) {
        final vals = vma[['VMA5', 'VMA10'][k]]!;
        final p = Path();
        var started = false;
        for (var i = 0; i < bars.length; i++) {
          final v = vals[offset + i];
          if (v == null) continue;
          final y = size.height - 3 - (maxV == 0 ? 0 : v / maxV * (subH - 6));
          if (!started) {
            p.moveTo(xOf(i), y);
            started = true;
          } else {
            p.lineTo(xOf(i), y);
          }
        }
        if (started) {
          canvas.drawPath(
            p,
            Paint()
              ..color = maColors[k]
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.9,
          );
        }
      }
      return;
    }

    // MACD：柱 + DIF/DEA 线
    if (subInd == 'MACD') {
      final m = macd(allBars);
      var lo = 0.0;
      var hi = 0.0;
      for (var i = offset; i < allBars.length; i++) {
        for (final v in [m.dif[i], m.dea[i], m.bar[i]]) {
          if (v == null) continue;
          if (v < lo) lo = v;
          if (v > hi) hi = v;
        }
      }
      final rng = (hi - lo) == 0 ? 1.0 : hi - lo;
      double yOf(double v) => top + 3 + (hi - v) / rng * (subH - 8);
      final zero = yOf(0);

      for (var i = 0; i < bars.length; i++) {
        final v = m.bar[offset + i];
        if (v == null) continue;
        final y = yOf(v);
        canvas.drawRect(
          Rect.fromLTRB(xOf(i) - step * 0.28, math.min(y, zero), xOf(i) + step * 0.28, math.max(y, zero)),
          Paint()..color = (v >= 0 ? up : down).withValues(alpha: 0.65),
        );
      }
      for (final pair in [
        [m.dif, maColors[0]],
        [m.dea, maColors[1]],
      ]) {
        final vals = pair[0] as List<double?>;
        final p = Path();
        var started = false;
        for (var i = 0; i < bars.length; i++) {
          final v = vals[offset + i];
          if (v == null) continue;
          final y = yOf(v);
          if (!started) {
            p.moveTo(xOf(i), y);
            started = true;
          } else {
            p.lineTo(xOf(i), y);
          }
        }
        if (started) {
          canvas.drawPath(
            p,
            Paint()
              ..color = pair[1] as Color
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1,
          );
        }
      }
      return;
    }

    // KDJ / RSI：0~100 区间折线
    if (subInd == 'KDJ') {
      final kd = kdj(allBars);
      _paintLines(
        canvas,
        bars,
        offset,
        top,
        subH,
        xOf,
        [
          [kd.k, maColors[0]],
          [kd.d, maColors[1]],
          [kd.j, maColors[2]],
        ],
        fixedLo: null,
        fixedHi: null,
      );
      return;
    }

    final r = rsi(allBars);
    _paintLines(
      canvas,
      bars,
      offset,
      top,
      subH,
      xOf,
      [
        [r, maColors[0]],
      ],
      fixedLo: 0,
      fixedHi: 100,
    );
  }

  void _paintLines(
    Canvas canvas,
    List<Bar> bars,
    int offset,
    double top,
    double subH,
    double Function(int) xOf,
    List<List<Object?>> series, {
    required double? fixedLo,
    required double? fixedHi,
  }) {
    var lo = fixedLo ?? double.infinity;
    var hi = fixedHi ?? double.negativeInfinity;
    if (fixedLo == null) {
      for (final s in series) {
        final vals = s[0] as List<double?>;
        for (var i = offset; i < vals.length; i++) {
          final v = vals[i];
          if (v == null) continue;
          if (v < lo) lo = v;
          if (v > hi) hi = v;
        }
      }
      if (lo == double.infinity) {
        lo = 0;
        hi = 100;
      }
    }
    final rng = (hi - lo) == 0 ? 1.0 : hi - lo;
    double yOf(double v) => top + 3 + (hi - v) / rng * (subH - 8);

    if (fixedLo != null) {
      // 画 20/80 参考线
      for (final lv in [20.0, 80.0]) {
        final y = yOf(lv);
        canvas.drawLine(
          Offset(xOf(0), y),
          Offset(xOf(bars.length - 1), y),
          Paint()
            ..color = grid
            ..strokeWidth = 0.5,
        );
      }
    }

    for (final s in series) {
      final vals = s[0] as List<double?>;
      final p = Path();
      var started = false;
      for (var i = 0; i < bars.length; i++) {
        final v = vals[offset + i];
        if (v == null) continue;
        final y = yOf(v);
        if (!started) {
          p.moveTo(xOf(i), y);
          started = true;
        } else {
          p.lineTo(xOf(i), y);
        }
      }
      if (started) {
        canvas.drawPath(
          p,
          Paint()
            ..color = s[1] as Color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.1,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_KlinePainter old) =>
      old.bars != bars ||
      old.chan != chan ||
      old.offset != offset ||
      old.subInd != subInd ||
      old.showMA != showMA ||
      old.showBoll != showBoll ||
      old.hollow != hollow;
}
