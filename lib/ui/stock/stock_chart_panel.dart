/// 对话页底部的 K 线面板：可展开 / 可缩回，展开时占内容区一部分高度。
///
/// 功能对齐 Eta 问股的 K 线面板：
///  - 级别切换：周 / 日 / 60 / 30 / 15 / 5
///  - 主图指标：MA、BOLL、缠论中枢、空心 K
///  - 副图指标：成交量、MACD、KDJ、RSI（互斥显示一个）
///
/// 交互形式保持不变：收起态是一行胶囊，点击展开；展开后可再点收起。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../stock/chanlun.dart';
import '../../stock/indicators.dart';
import '../../stock/chart_shapes.dart';
import '../../stock/shape_colors.dart';
import '../../stock/shape_store.dart';
import '../../stock/minute.dart';
import '../../stock/stock_bridge.dart';
import '../../stock/stock_source.dart';
import '../../stock/watchlist_store.dart';

import 'chart_gesture.dart';
import 'stock_search_sheet.dart';
import 'watchlist_drawer.dart';

/// 主图指标键，顺序与 Eta 的 `MAIN_IND_KEYS` 一致。
const mainIndKeys = ['MA', 'BOLL', 'CHAN', 'HOLLOW'];

/// 副图指标键，顺序与 Eta 的 `SUB_IND_KEYS` 一致。
const subIndKeys = ['VOL', 'MACD', 'KDJ', 'RSI'];

/// 周期顺序与 Eta 的 LEVELS 一致，末尾补 month（Eta 没有，本项目保留）。
/// `minute` 是分时，走独立取数通道，不参与缠论计算。
const _periodLabels = <String, String>{
  'minute': '分时',
  'day': '日',
  'week': '周',
  'month': '月',
  'm60': '60',
  'm30': '30',
  'm15': '15',
  'm5': '5',
};

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

  /// 副图指标：可多选，空集表示只显示主图。
  final Set<String> _subOn = {'VOL'};

  String get symbol => _symbol;
  String get period => _period;
  bool get expanded => _expanded;

  /// 当前开启的副图指标（按固定顺序返回，避免切换时面板顺序跳动）。
  List<String> get subInds => [
    for (final k in subIndKeys)
      if (_subOn.contains(k)) k,
  ];

  bool isSubOn(String key) => _subOn.contains(key);

  /// 点一下切换；不选任何副图时面板只留主图。
  void toggleSub(String key) {
    if (!_subOn.remove(key)) _subOn.add(key);
    notifyListeners();
  }

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

  /// 最近一次解析到的股票名，联动切股时有值。
  String? _name;
  String? get name => _name;

  /// 联动用：确保面板展开（幂等）。
  void ensureExpanded() {
    if (_expanded) return;
    _expanded = true;
    notifyListeners();
  }

  void setSymbol(String v, {String? name}) {
    final s = v.trim();
    if (s.isEmpty) return;
    if (s == _symbol && name == null) return;
    _symbol = s;
    if (name != null) _name = name;
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

  bool get showMA => mainOn['MA'] ?? false;
  bool get showBoll => mainOn['BOLL'] ?? false;
  bool get showChan => mainOn['CHAN'] ?? false;
  bool get hollow => mainOn['HOLLOW'] ?? false;
}

/// 全局单例：会话之间共用一个面板。
final stockPanel = StockPanelState();

/// 把面板接到工具层的桥：模型调用 stock_panel_show 时走这里。
class _PanelRequest implements StockPanelRequest {
  @override
  Future<bool> show(String code, {String? period}) async {
    stockPanel.ensureExpanded();
    stockPanel.setSymbol(code);
    if (period != null && period.isNotEmpty) stockPanel.setPeriod(period);
    return true;
  }

  @override
  bool get visible => stockPanel.expanded;
}

/// App 启动时调用一次，把真实实现交给工具层。
void installStockPanelBridge() {
  installStockPanelRequest(_PanelRequest());
}

class StockChartPanel extends StatefulWidget {
  const StockChartPanel({super.key, required this.state, this.source, this.onAsk, this.maxHeight = 380});

  final StockPanelState state;

  /// 「问这根 K 线」把拼好的问句交给对话区。
  final void Function(String text)? onAsk;

  /// 与工具层共用的数据源；传 null 时面板自建一个。
  final StockSource? source;
  final double maxHeight;

  @override
  State<StockChartPanel> createState() => _StockChartPanelState();
}

class _StockChartPanelState extends State<StockChartPanel> {
  StockSource? _ownSource;
  KlineSeries? _series;
  MinuteSeries? _minute;
  ChanResult? _chan;
  Quote? _quote;
  String? _error;
  bool _loading = false;
  String _lastKey = '';

  final _viewport = ChartViewport();
  final _cross = CrosshairState();

  /// 当前指针指向的 K 线索引（用于「问这根」和顶部数值条）。
  int _focus = -1;

  /// 自选抽屉是否展开。
  bool _drawerOpen = false;

  /// 当前图的画线。
  List<ChartShape> _shapes = const [];

  final _watch = WatchlistStore.instance;

  bool get _isMinute => widget.state.period == 'minute';

  StockSource get _src => widget.source ?? (_ownSource ??= sharedStockSource);

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onStateChanged);
    unawaited(_watch.load());
    if (widget.state.expanded) _load();
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    // 共享数据源不关：其他面板/工具还在用同一条连接与缓存。
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
      _focus = -1;
      _cross.clear();
    });

    // 行情卡与主数据并行取，互不阻塞。
    unawaited(
      _src
          .quote(widget.state.symbol)
          .then((q) {
            if (!mounted || _lastKey != key) return;
            setState(() => _quote = q);
          })
          .catchError((Object _) {}),
    );

    try {
      if (_isMinute) {
        // 分时：独立通道，不算缠论（与 Eta 一致）。
        final m = await _src.minuteCached(widget.state.symbol);
        if (!mounted || _lastKey != key) return;
        _viewport.showAll(m.points.length);
        setState(() {
          _minute = m;
          _series = null;
          _chan = null;
          _loading = false;
        });
        return;
      }

      final s = await _src.klineCached(widget.state.symbol, period: widget.state.period);
      if (!mounted || _lastKey != key) return;
      ChanResult? ch;
      if (widget.state.showChan) {
        ch = Chanlun.analyze(s.bars, await _formula());
      }
      _viewport.reset(s.bars.length);
      final shapes = await ShapeStore.instance.load(widget.state.symbol, widget.state.period);
      if (!mounted || _lastKey != key) return;
      setState(() {
        _series = s;
        _minute = null;
        _chan = ch;
        _shapes = shapes;
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
      child: Stack(
        children: [
          Column(
            children: [
              _PeriodRow(
                state: widget.state,
                onCollapse: widget.state.collapse,
                onAskBar: _canAsk ? _askAboutFocus : null,
                onSearch: _openSearch,
                onAddToWatch: _addCurrentToWatch,
                onWatchlist: () => setState(() => _drawerOpen = !_drawerOpen),
                watchlistActive: _drawerOpen,
              ),
              if (_quote != null || _focusBar != null)
                _QuoteBar(quote: _quote, focusBar: _focusBar, focusDate: _focusDate),
              _IndBar(state: widget.state, onChange: _syncChan),
              Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.35)),
              Expanded(child: _buildBody(scheme)),
            ],
          ),
          if (_drawerOpen)
            Positioned.fill(
              child: WatchlistDrawer(
                store: _watch,
                currentCode: widget.state.symbol,
                onPick: (code, name) {
                  setState(() => _drawerOpen = false);
                  widget.state.setSymbol(code);
                },
                onClose: () => setState(() => _drawerOpen = false),
              ),
            ),
        ],
      ),
    );
  }

  /// 打开搜索浮层，选中后切股。
  Future<void> _openSearch() async {
    final hit = await showStockSearch(context, _src.search);
    if (!mounted || hit == null) return;
    widget.state.setSymbol(hit.fullCode);
  }

  /// 把当前股票加进自选（默认第一个分组）。
  Future<void> _addCurrentToWatch() async {
    final s = _series;
    final name = s?.name ?? _quote?.name ?? widget.state.symbol;
    await _watch.add(widget.state.symbol, name);
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text('已加入自选：$name'), duration: const Duration(seconds: 2)));
  }

  /// 当前关注的那根 K 线：优先十字光标，其次最后一次点选。
  int get _focusIdx => _cross.active ? _cross.index : _focus;

  Bar? get _focusBar {
    final s = _series;
    if (s == null) return null;
    final i = _focusIdx;
    if (i < 0 || i >= s.bars.length) return null;
    return s.bars[i];
  }

  String? get _focusDate {
    final s = _series;
    if (s == null) return null;
    final i = _focusIdx;
    if (i < 0 || i >= s.bars.length) return null;
    return s.bars[i].t;
  }

  bool get _canAsk => _focusBar != null;

  /// 把选中那根的完整数据拼成一句话问 AI（与 Eta 的「问 Eta 这根 K 线」同构）。
  void _askAboutFocus() {
    final b = _focusBar;
    final s = _series;
    if (b == null || s == null) return;
    final label = _periodLabels[widget.state.period] ?? widget.state.period;
    // ★ 汉字紧跟标识符会被当成变量名的一部分（$labelK线 → 变量 labelK线），必须断开。
    final text =
        '请解读 ${s.name}(${s.symbol}) 在 ${b.t} 这根 ${label}K线：'
        '开 ${b.o.toStringAsFixed(2)}，高 ${b.h.toStringAsFixed(2)}，'
        '低 ${b.l.toStringAsFixed(2)}，收 ${b.c.toStringAsFixed(2)}，'
        '量 ${b.v.toStringAsFixed(0)}。'
        '这个位置的多空含义是什么？后续可能怎么走？';
    widget.onAsk?.call(text);
    setState(() {
      _cross.clear();
      _focus = -1;
    });
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
    if (_isMinute) {
      final m = _minute;
      if (m == null || m.points.isEmpty) {
        return Center(
          child: Text('暂无分时数据', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
        );
      }
      return _MinuteCanvas(series: m, scheme: scheme);
    }

    final s = _series;
    if (s == null || s.bars.isEmpty) {
      return Center(
        child: Text('暂无数据', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
      );
    }

    return ChartGestureLayer(
      viewport: _viewport,
      onCrosshair: (i) => setState(() {
        _cross.active = i >= 0;
        _cross.index = i;
      }),
      onTapBar: (i) => setState(() {
        _focus = i;
        _cross.clear();
      }),
      onLongPressRelease: (i) => setState(() {
        _focus = i;
        _cross.clear();
      }),
      child: ListenableBuilder(
        listenable: _viewport,
        builder: (context, _) => _KlineCanvas(
          series: s,
          chan: _chan,
          viewport: _viewport,
          crossIndex: _cross.active ? _cross.index : -1,
          focusIndex: _focus,
          subInds: widget.state.subInds,
          showMA: widget.state.showMA,
          showBoll: widget.state.showBoll,
          hollow: widget.state.hollow,
          shapes: _shapes,
          scheme: scheme,
        ),
      ),
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
  const _PeriodRow({
    required this.state,
    required this.onCollapse,
    this.onAskBar,
    this.onSearch,
    this.onAddToWatch,
    this.onWatchlist,
    this.watchlistActive = false,
  });

  final StockPanelState state;
  final VoidCallback onCollapse;

  /// 非空时显示「问」按钮（选中某根 K 线后才出现）。
  final VoidCallback? onAskBar;

  /// 右上角搜索。
  final VoidCallback? onSearch;

  /// 右上角「加入自选」。
  final VoidCallback? onAddToWatch;

  /// 左侧自选抽屉开关。
  final VoidCallback? onWatchlist;
  final bool watchlistActive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
      child: Row(
        children: [
          if (onWatchlist != null)
            GestureDetector(
              onTap: onWatchlist,
              child: Container(
                margin: const EdgeInsets.only(right: 4),
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: watchlistActive ? scheme.primary.withValues(alpha: 0.16) : Colors.transparent,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(Icons.star_outline_rounded, size: 15, color: scheme.primary),
              ),
            ),
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
          if (onAskBar != null)
            GestureDetector(
              onTap: onAskBar,
              child: Container(
                margin: const EdgeInsets.only(right: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.chat_bubble_outline_rounded, size: 12, color: scheme.primary),
                    const SizedBox(width: 3),
                    Text('问这根', style: TextStyle(fontSize: 11, color: scheme.primary)),
                  ],
                ),
              ),
            ),
          if (onAddToWatch != null)
            InkWell(
              onTap: onAddToWatch,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Icon(Icons.add_circle_outline_rounded, size: 17, color: scheme.onSurfaceVariant),
              ),
            ),
          if (onSearch != null)
            InkWell(
              onTap: onSearch,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Icon(Icons.search_rounded, size: 17, color: scheme.onSurfaceVariant),
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
/// 指标横条：**主图与副图同一行、左右分栏**，各自可横向滑动。
///
/// 左侧主图指标（MA/BOLL/缠论/空心K），右侧副图指标（量/MACD/KDJ/RSI）。
/// 中间一条细分隔线，两侧互不干扰地各自滚动。
class _IndBar extends StatelessWidget {
  const _IndBar({required this.state, required this.onChange});

  final StockPanelState state;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: SizedBox(
        height: 26,
        child: Row(
          children: [
            // 左：主图指标
            Expanded(
              flex: 1,
              child: Row(
                children: [
                  _tag('主', scheme),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
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
                  ),
                ],
              ),
            ),
            // 中：分隔
            Container(
              width: 1,
              height: 16,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
            // 右：副图指标
            Expanded(
              flex: 1,
              child: Row(
                children: [
                  _tag('副', scheme),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final k in subIndKeys)
                            _Chip(label: indLabel(k), selected: state.isSubOn(k), onTap: () => state.toggleSub(k)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tag(String text, ColorScheme scheme) => Padding(
    padding: const EdgeInsets.only(right: 4),
    child: Text(text, style: TextStyle(fontSize: 9.5, color: scheme.onSurfaceVariant)),
  );
}

/// 行情条：现价/涨跌，或选中那根 K 线的开高低收。
class _QuoteBar extends StatelessWidget {
  const _QuoteBar({required this.quote, required this.focusBar, required this.focusDate});

  final Quote? quote;
  final Bar? focusBar;
  final String? focusDate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final up = const Color(0xFFE5484D);
    final down = const Color(0xFF30A46C);

    final b = focusBar;
    if (b != null) {
      // 选中某根：显示这根自己的数据（与 Eta 的光标信息条一致）
      final isUp = b.c >= b.o;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: Row(
          children: [
            Text(
              focusDate ?? '',
              style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            _kv('开', b.o.toStringAsFixed(2), scheme),
            _kv('高', b.h.toStringAsFixed(2), scheme),
            _kv('低', b.l.toStringAsFixed(2), scheme),
            _kv('收', b.c.toStringAsFixed(2), scheme, color: isUp ? up : down),
            _kv('量', _fmtVol(b.v), scheme),
          ],
        ),
      );
    }

    final q = quote;
    if (q == null) return const SizedBox.shrink();
    final color = q.change >= 0 ? up : down;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Row(
        children: [
          Text(
            q.name,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scheme.onSurface),
          ),
          const SizedBox(width: 6),
          Text(
            q.price.toStringAsFixed(2),
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
          ),
          const SizedBox(width: 4),
          Text(
            '${q.change >= 0 ? '+' : ''}${q.change.toStringAsFixed(2)} ${q.changePct.toStringAsFixed(2)}%',
            style: TextStyle(fontSize: 10, color: color),
          ),
          const Spacer(),
          _kv('开', q.open.toStringAsFixed(2), scheme),
          _kv('高', q.high.toStringAsFixed(2), scheme),
          _kv('低', q.low.toStringAsFixed(2), scheme),
        ],
      ),
    );
  }

  Widget _kv(String k, String v, ColorScheme scheme, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.only(left: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(k, style: TextStyle(fontSize: 9.5, color: scheme.onSurfaceVariant)),
          const SizedBox(width: 2),
          Text(v, style: TextStyle(fontSize: 10, color: color ?? scheme.onSurface)),
        ],
      ),
    );
  }

  static String _fmtVol(double v) {
    if (v >= 100000000) return '${(v / 100000000).toStringAsFixed(2)}亿';
    if (v >= 10000) return '${(v / 10000).toStringAsFixed(1)}万';
    return v.toStringAsFixed(0);
  }
}

/// 分时图：价格线 + 均价线 + 量柱，X 轴按全天时间等分（不是按根数）。
class _MinuteCanvas extends StatelessWidget {
  const _MinuteCanvas({required this.series, required this.scheme});

  final MinuteSeries series;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => CustomPaint(
        size: Size(c.maxWidth, c.maxHeight),
        painter: _MinutePainter(
          series: series,
          up: const Color(0xFFE5484D),
          down: const Color(0xFF30A46C),
          grid: scheme.outlineVariant.withValues(alpha: 0.35),
          text: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _MinutePainter extends CustomPainter {
  _MinutePainter({required this.series, required this.up, required this.down, required this.grid, required this.text});

  final MinuteSeries series;
  final Color up;
  final Color down;
  final Color grid;
  final Color text;

  /// A 股全天 241 个点（9:30–11:30 + 13:00–15:00）。
  static const fullDay = 242;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = series.points;
    if (pts.isEmpty) return;

    const padLeft = 2.0;
    const padRight = 46.0;
    const padTop = 4.0;
    final subH = size.height * 0.24;
    final mainH = size.height - subH - padTop - 2;
    final w = size.width - padLeft - padRight;
    if (w <= 0 || mainH <= 0) return;

    final prev = series.prevClose;
    final dev = series.maxDeviation();
    final pad = dev == 0 ? 1.0 : dev * 1.1;
    final hi = prev + pad;
    final lo = prev - pad;
    final span = hi - lo;

    double yOf(double p) => padTop + (hi - p) / span * mainH;
    double xOf(int i) => padLeft + (i / (fullDay - 1)) * w;

    // 纵向网格 + 右侧价格
    final gp = Paint()
      ..color = grid
      ..strokeWidth = 0.6;
    final ts = TextStyle(color: text, fontSize: 8.5);
    for (var i = 0; i <= 4; i++) {
      final y = padTop + mainH * i / 4;
      canvas.drawLine(Offset(padLeft, y), Offset(padLeft + w, y), gp);
      final price = hi - span * i / 4;
      final tp = TextPainter(
        text: TextSpan(text: price.toStringAsFixed(2), style: ts),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(padLeft + w + 3, y - tp.height / 2));
    }

    // 昨收线（虚线感：用浅色实线代替）
    final py = yOf(prev);
    canvas.drawLine(
      Offset(padLeft, py),
      Offset(padLeft + w, py),
      Paint()
        ..color = grid
        ..strokeWidth = 0.8,
    );

    // 价格线
    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final x = xOf(i);
      final y = yOf(pts[i].price);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final lineColor = series.lastPrice >= prev ? up : down;
    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    // 成交量柱（按累计量差分）
    var prevVol = 0.0;
    final vols = <double>[];
    for (final p in pts) {
      vols.add((p.volume - prevVol).clamp(0, double.infinity));
      prevVol = p.volume;
    }
    var maxV = 0.0;
    for (final v in vols) {
      if (v > maxV) maxV = v;
    }
    if (maxV > 0) {
      final bw = math.max(0.6, w / fullDay * 0.7);
      for (var i = 0; i < pts.length; i++) {
        final h = vols[i] / maxV * (subH - 4);
        final x = xOf(i);
        canvas.drawRect(
          Rect.fromLTRB(x - bw / 2, size.height - 2 - h, x + bw / 2, size.height - 2),
          Paint()..color = (pts[i].price >= prev ? up : down).withValues(alpha: 0.45),
        );
      }
    }

    // 时间刻度：9:30 / 11:30 / 13:00 / 15:00
    final marks = <int, String>{0: '9:30', 120: '11:30', 121: '13:00', 241: '15:00'};
    for (final e in marks.entries) {
      final x = xOf(e.key);
      if (x > padLeft + w) continue;
      final tp = TextPainter(
        text: TextSpan(text: e.value, style: ts),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, size.height - tp.height - 1));
    }
  }

  @override
  bool shouldRepaint(_MinutePainter old) => old.series != series;
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
    required this.viewport,
    required this.crossIndex,
    required this.focusIndex,
    required this.subInds,
    required this.showMA,
    required this.showBoll,
    required this.hollow,
    required this.shapes,
    required this.scheme,
  });

  final KlineSeries series;
  final ChanResult? chan;
  final ChartViewport viewport;

  /// 十字光标指向的索引；-1 表示不显示。
  final int crossIndex;

  /// 点选高亮的索引；-1 表示无。
  final int focusIndex;
  final List<String> subInds;
  final bool showMA;
  final bool showBoll;
  final bool hollow;
  final List<ChartShape> shapes;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final bars = series.bars;
    final start = viewport.start.clamp(0, bars.length);
    final end = (start + viewport.visible).clamp(start, bars.length);
    final show = bars.sublist(start, end);

    return LayoutBuilder(
      builder: (context, c) {
        return CustomPaint(
          size: Size(c.maxWidth, c.maxHeight),
          painter: _KlinePainter(
            bars: show,
            allBars: bars,
            offset: start,
            chan: chan,
            crossIndex: crossIndex,
            focusIndex: focusIndex,
            subInds: subInds,
            showMA: showMA,
            showBoll: showBoll,
            hollow: hollow,
            shapes: shapes,
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
    required this.crossIndex,
    required this.focusIndex,
    required this.subInds,
    required this.showMA,
    required this.showBoll,
    required this.hollow,
    required this.shapes,
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
  final int crossIndex;
  final int focusIndex;
  final List<String> subInds;
  final bool showMA;
  final bool showBoll;
  final bool hollow;
  final List<ChartShape> shapes;
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
    // 副图总高度：没选任何副图就不占；选了多个按 0.20/个，上限占 45%。
    final nSub = subInds.length;
    final subH = nSub == 0 ? 0.0 : math.min(size.height * 0.45, size.height * 0.20 * nSub);
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

    // ---- 缠论：笔 + 中枢 ----
    final ch = chan;
    if (ch != null) {
      // 笔：把转折点连成折线（Eta 的 pen 线）。
      // 先画，避免盖住蜡烛；颜色用醒目的金黄，和中枢框区分。
      if (ch.pens.length >= 2) {
        final penPath = Path();
        var started = false;
        for (final p in ch.pens) {
          final i = p.idx - offset;
          // 完全在窗口外的点跳过，但保留跨窗口的连接
          if (p.idx < offset - 1 || p.idx > offset + bars.length) continue;
          final x = padLeft + (i + 0.5) * step;
          final y = yOf(p.price);
          if (!started) {
            penPath.moveTo(x, y);
            started = true;
          } else {
            penPath.lineTo(x, y);
          }
        }
        if (started) {
          canvas.drawPath(
            penPath,
            Paint()
              ..color = const Color(0xFFE8C63D).withValues(alpha: 0.9)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.1,
          );
        }

        // 笔的转折点小圆点
        for (final p in ch.pens) {
          final i = p.idx - offset;
          if (i < 0 || i >= bars.length) continue;
          canvas.drawCircle(
            Offset(padLeft + (i + 0.5) * step, yOf(p.price)),
            1.8,
            Paint()..color = const Color(0xFFE8C63D),
          );
        }
      }

      // 背驰信号：在对应 K 线上打标记
      for (final sig in ch.signals) {
        final i = sig.idx - offset;
        if (i < 0 || i >= bars.length) continue;
        final x = padLeft + (i + 0.5) * step;
        final y = yOf(sig.price);
        final isBuy = sig.type == 'buy';
        final c = isBuy ? up : down;
        // 买点画在下方朝上的三角，卖点画在上方朝下的三角
        final dy = isBuy ? 9.0 : -9.0;
        final path = Path();
        if (isBuy) {
          path.moveTo(x, y - dy);
          path.lineTo(x - 3.5, y - dy + 6);
          path.lineTo(x + 3.5, y - dy + 6);
        } else {
          path.moveTo(x, y - dy);
          path.lineTo(x - 3.5, y - dy - 6);
          path.lineTo(x + 3.5, y - dy - 6);
        }
        path.close();
        canvas.drawPath(path, Paint()..color = c.withValues(alpha: 0.85));
      }

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

    // ---- 选中高亮 + 十字光标 ----
    final fi = focusIndex - offset;
    if (fi >= 0 && fi < bars.length) {
      canvas.drawRect(
        Rect.fromLTRB(padLeft + fi * step, padTop, padLeft + (fi + 1) * step, padTop + mainH),
        Paint()..color = up.withValues(alpha: 0.06),
      );
    }
    final ci = crossIndex - offset;
    if (ci >= 0 && ci < bars.length) {
      final cx = xOf(ci);
      final crossPaint = Paint()
        ..color = text.withValues(alpha: 0.65)
        ..strokeWidth = 0.9;
      canvas.drawLine(Offset(cx, padTop), Offset(cx, size.height - 2), crossPaint);
      final cy = yOf(bars[ci].c);
      canvas.drawLine(Offset(padLeft, cy), Offset(padLeft + chartW, cy), crossPaint);
      // 右侧价格气泡
      final tp = TextPainter(
        text: TextSpan(
          text: bars[ci].c.toStringAsFixed(2),
          style: TextStyle(color: (bars[ci].c >= bars[ci].o ? up : down), fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final bh = tp.height + 4;
      final rect = Rect.fromLTWH(padLeft + chartW + 1, cy - bh / 2, padRight - 2, bh);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(3)), Paint()..color = grid);
      tp.paint(canvas, Offset(rect.left + 3, rect.top + 2));
    }

    // ---- 用户画线 ----
    _paintShapes(canvas, padLeft, padTop, chartW, step, xOf, yOf, mainH);

    // ---- 副图 ----
    _paintSub(canvas, size, chartW, padLeft, subH, maxV);
  }

  /// 画用户图层。坐标是「K 线索引 + 价格」，这里换算成像素。
  void _paintShapes(
    Canvas canvas,
    double padLeft,
    double padTop,
    double chartW,
    double step,
    double Function(int) xOf,
    double Function(double) yOf,
    double mainH,
  ) {
    if (shapes.isEmpty) return;

    // 索引 → x。可视区外的点照样能画（会超出边界，靠裁剪挡住）。
    double xAt(int idx) => padLeft + (idx - offset + 0.5) * step;

    for (final sh in shapes) {
      final color = shapeColorValue(sh.color);
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke;

      switch (sh.kind) {
        case ShapeKind.hline:
          final y = yOf(sh.p1);
          if (y < padTop || y > padTop + mainH) break;
          canvas.drawLine(Offset(padLeft, y), Offset(padLeft + chartW, y), paint);
          _label(canvas, sh.p1.toStringAsFixed(2), Offset(padLeft + chartW + 3, y - 8), color);

        case ShapeKind.trendline:
          if (sh.i2 == null || sh.p2 == null) break;
          canvas.drawLine(Offset(xAt(sh.i1), yOf(sh.p1)), Offset(xAt(sh.i2!), yOf(sh.p2!)), paint);

        case ShapeKind.ray:
          if (sh.i2 == null || sh.p2 == null) break;
          final x1 = xAt(sh.i1);
          final y1 = yOf(sh.p1);
          final x2 = xAt(sh.i2!);
          final y2 = yOf(sh.p2!);
          if (x2 == x1) break;
          // 延伸到右边界
          final t = (padLeft + chartW - x1) / (x2 - x1);
          canvas.drawLine(Offset(x1, y1), Offset(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t), paint);

        case ShapeKind.rect:
          if (sh.i2 == null || sh.p2 == null) break;
          final r = Rect.fromPoints(Offset(xAt(sh.i1), yOf(sh.p1)), Offset(xAt(sh.i2!), yOf(sh.p2!)));
          canvas.drawRect(r, Paint()..color = color.withValues(alpha: 0.08));
          canvas.drawRect(r, paint);

        case ShapeKind.text:
          _label(canvas, sh.text ?? '', Offset(xAt(sh.i1), yOf(sh.p1)), color);

        case ShapeKind.arrow:
          if (sh.i2 == null || sh.p2 == null) break;
          final from = Offset(xAt(sh.i1), yOf(sh.p1));
          final to = Offset(xAt(sh.i2!), yOf(sh.p2!));
          canvas.drawLine(from, to, paint);
          _arrowHead(canvas, from, to, color);

        case ShapeKind.dot:
          canvas.drawCircle(Offset(xAt(sh.i1), yOf(sh.p1)), 2.6, Paint()..color = color);
      }
    }
  }

  void _label(Canvas canvas, String text, Offset at, Color color) {
    if (text.isEmpty) return;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: 9.5),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  void _arrowHead(Canvas canvas, Offset from, Offset to, Color color) {
    final dir = to - from;
    final len = dir.distance;
    if (len < 1) return;
    final unit = dir / len;
    final normal = Offset(-unit.dy, unit.dx);
    const size = 6.0;
    final p1 = to - unit * size + normal * (size * 0.45);
    final p2 = to - unit * size - normal * (size * 0.45);
    final path = Path()
      ..moveTo(to.dx, to.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  /// 副图：按选中的指标平分副图区域，从上到下依次排列。
  void _paintSub(Canvas canvas, Size size, double chartW, double padLeft, double subH, double maxV) {
    if (subInds.isEmpty || subH <= 0) return;

    final top = size.height - subH;
    final each = subH / subInds.length;

    for (var i = 0; i < subInds.length; i++) {
      final kind = subInds[i];
      final panelTop = top + i * each;

      // 每个副图区域之间的分隔线
      canvas.drawLine(
        Offset(padLeft, panelTop),
        Offset(padLeft + chartW, panelTop),
        Paint()
          ..color = grid
          ..strokeWidth = 0.6,
      );

      // 左上角标出指标名，多副图并排时不至于看不懂
      final tp = TextPainter(
        text: TextSpan(
          text: indLabel(kind),
          style: TextStyle(color: text, fontSize: 8.5),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(padLeft + 2, panelTop + 1));

      _paintOneSub(canvas, kind, chartW, padLeft, panelTop, each, maxV);
    }
  }

  void _paintOneSub(Canvas canvas, String kind, double chartW, double padLeft, double top, double subH, double maxV) {
    final step = chartW / bars.length;
    double xOf(int i) => padLeft + (i + 0.5) * step;
    final bottom = top + subH;

    if (kind == 'VOL') {
      final vma = volMaSeries(allBars, [5, 10]);
      for (var i = 0; i < bars.length; i++) {
        final b = bars[i];
        final h = maxV == 0 ? 0.0 : b.v / maxV * (subH - 8);
        final isUp = b.c >= b.o;
        canvas.drawRect(
          Rect.fromLTRB(xOf(i) - step * 0.31, bottom - 3 - h, xOf(i) + step * 0.31, bottom - 3),
          Paint()..color = (isUp ? up : down).withValues(alpha: 0.5),
        );
      }
      for (var k = 0; k < 2; k++) {
        final vals = vma[['VMA5', 'VMA10'][k]]!;
        final p = Path();
        var started = false;
        for (var i = 0; i < bars.length; i++) {
          final v = vals[offset + i];
          if (v == null) continue;
          final y = bottom - 3 - (maxV == 0 ? 0 : v / maxV * (subH - 8));
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

    if (kind == 'MACD') {
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
      double yOf(double v) => top + 4 + (hi - v) / rng * (subH - 10);
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
      _drawSeries(canvas, bars, offset, [m.dif, maColors[0]], xOf, yOf);
      _drawSeries(canvas, bars, offset, [m.dea, maColors[1]], xOf, yOf);
      return;
    }

    if (kind == 'KDJ') {
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

  /// 画一条线（值为 null 处断开）。
  void _drawSeries(
    Canvas canvas,
    List<Bar> bars,
    int offset,
    List<Object?> series,
    double Function(int) xOf,
    double Function(double) yOf,
  ) {
    final vals = series[0] as List<double?>;
    final color = series[1] as Color;
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
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
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
      old.crossIndex != crossIndex ||
      old.focusIndex != focusIndex ||
      !listEquals(old.subInds, subInds) ||
      old.showMA != showMA ||
      old.showBoll != showBoll ||
      old.hollow != hollow ||
      old.shapes != shapes;
}
