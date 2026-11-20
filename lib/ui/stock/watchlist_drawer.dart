/// 面板内的自选股抽屉：分组管理 + 个股列表 + 分组平均涨跌。
///
/// 分组能力：新建/重命名/删除/排序，批量移入、批量移出。
/// 顶部显示当前分组的等权平均涨跌幅。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../stock/group_stats.dart';
import '../../stock/stock_source.dart';
import '../../stock/watchlist_store.dart';

class WatchlistDrawer extends StatefulWidget {
  const WatchlistDrawer({
    super.key,
    required this.store,
    required this.currentCode,
    required this.onPick,
    required this.onClose,
  });

  final WatchlistStore store;
  final String currentCode;
  final void Function(String code, String name) onPick;
  final VoidCallback onClose;

  @override
  State<WatchlistDrawer> createState() => _WatchlistDrawerState();
}

class _WatchlistDrawerState extends State<WatchlistDrawer> {
  String _group = '';

  /// 当前分组各只股票的涨跌幅。
  final Map<String, double?> _pct = {};
  GroupStats? _stats;
  bool _loadingStats = false;

  /// 批量选择模式。
  bool _batch = false;
  final Set<String> _picked = {};

  @override
  void initState() {
    super.initState();
    _group = widget.store.groups.isEmpty ? '' : widget.store.groups.first.id;
    widget.store.addListener(_onStore);
    unawaited(_loadStats());
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStore);
    super.dispose();
  }

  void _onStore() {
    if (!mounted) return;
    // 分组被删掉后回落到第一个
    if (!widget.store.groups.any((g) => g.id == _group)) {
      _group = widget.store.groups.isEmpty ? '' : widget.store.groups.first.id;
    }
    setState(() {});
    unawaited(_loadStats());
  }

  /// 拉当前分组所有股票的涨跌幅，算平均。
  Future<void> _loadStats() async {
    final items = widget.store.inGroup(_group);
    if (items.isEmpty) {
      if (mounted) {
        setState(() {
          _stats = GroupStats(count: 0, avgPct: null, up: 0, down: 0, missing: 0);
          _pct.clear();
        });
      }
      return;
    }
    if (mounted) setState(() => _loadingStats = true);

    final quotes = await Future.wait([
      for (final it in items)
        sharedStockSource
            .quoteCached(it.code)
            .then<GroupMemberQuote?>((q) {
              _pct[it.code] = q.changePct;
              return GroupMemberQuote(code: it.code, changePct: q.changePct);
            })
            .catchError((Object _) {
              _pct[it.code] = null;
              return null;
            }),
    ]);

    if (!mounted) return;
    setState(() {
      _stats = computeGroupStats(quotes);
      _loadingStats = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = widget.store.inGroup(_group);

    return GestureDetector(
      onTap: widget.onClose,
      child: Container(
        color: Colors.black.withValues(alpha: 0.25),
        child: Align(
          alignment: Alignment.centerLeft,
          child: GestureDetector(
            onTap: () {},
            child: Container(
              width: 196,
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: const BorderRadius.horizontal(right: Radius.circular(14)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(scheme),
                  _groupsRow(scheme),
                  _statsBar(scheme),
                  Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
                  Expanded(child: _list(scheme, items)),
                  if (_batch) _batchBar(scheme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 4),
      child: Row(
        children: [
          Text(
            '自选',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurface),
          ),
          const Spacer(),
          InkWell(
            onTap: () => setState(() {
              _batch = !_batch;
              _picked.clear();
            }),
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Icon(
                _batch ? Icons.close_rounded : Icons.checklist_rounded,
                size: 15,
                color: _batch ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ),
          InkWell(
            onTap: _groupMenu,
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Icon(Icons.tune_rounded, size: 15, color: scheme.onSurfaceVariant),
            ),
          ),
          InkWell(
            onTap: widget.onClose,
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Icon(Icons.close_rounded, size: 15, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// 分组横条：横向滚动，长按可重命名/删除。
  Widget _groupsRow(ColorScheme scheme) {
    return SizedBox(
      height: 28,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final g in widget.store.groups)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    _group = g.id;
                    _picked.clear();
                  });
                  unawaited(_loadStats());
                },
                onLongPress: () => _groupActions(g),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _group == g.id ? scheme.primary.withValues(alpha: 0.16) : Colors.transparent,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    g.name,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: _group == g.id ? scheme.primary : scheme.onSurfaceVariant,
                      fontWeight: _group == g.id ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
          // 新建分组
          InkWell(
            onTap: _newGroup,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Icon(Icons.add_rounded, size: 14, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// 分组平均涨跌。
  Widget _statsBar(ColorScheme scheme) {
    final st = _stats;
    if (st == null || !st.hasData) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 5),
        child: Text(_loadingStats ? '统计中…' : '暂无行情', style: TextStyle(fontSize: 9.5, color: scheme.onSurfaceVariant)),
      );
    }
    final avg = st.avgPct!;
    final up = const Color(0xFFE5484D);
    final down = const Color(0xFF30A46C);
    final color = avg > 0 ? up : (avg < 0 ? down : scheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 5),
      child: Row(
        children: [
          Text('均', style: TextStyle(fontSize: 9.5, color: scheme.onSurfaceVariant)),
          const SizedBox(width: 3),
          Text(
            '${avg >= 0 ? '+' : ''}${avg.toStringAsFixed(2)}%',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color),
          ),
          const Spacer(),
          Text('涨${st.up} 跌${st.down}', style: TextStyle(fontSize: 9, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _list(ColorScheme scheme, List<WatchItem> items) {
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            '这个分组还没有股票\n用面板右上角 ⊕ 添加',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    final up = const Color(0xFFE5484D);
    final down = const Color(0xFF30A46C);

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 2),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final it = items[i];
        final sel = it.code == widget.currentCode;
        final picked = _picked.contains(it.code);
        final pct = _pct[it.code];

        return InkWell(
          onTap: () {
            if (_batch) {
              setState(() {
                if (!_picked.remove(it.code)) _picked.add(it.code);
              });
            } else {
              widget.onPick(it.code, it.name);
            }
          },
          onLongPress: () {
            if (!_batch) {
              setState(() {
                _batch = true;
                _picked.add(it.code);
              });
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: picked
                ? scheme.primary.withValues(alpha: 0.12)
                : (sel ? scheme.primary.withValues(alpha: 0.06) : null),
            child: Row(
              children: [
                if (_batch)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(
                      picked ? Icons.check_circle_rounded : Icons.circle_outlined,
                      size: 13,
                      color: picked ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        it.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: sel && !_batch ? scheme.primary : scheme.onSurface,
                          fontWeight: sel && !_batch ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      Text(
                        it.code.replaceFirst(RegExp(r'^(sh|sz|bj)'), ''),
                        style: TextStyle(fontSize: 9, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (pct != null)
                  Text(
                    '${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(2)}%',
                    style: TextStyle(fontSize: 10, color: pct > 0 ? up : (pct < 0 ? down : scheme.onSurfaceVariant)),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 批量操作条。
  Widget _batchBar(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4))),
      ),
      child: Row(
        children: [
          Text('已选 ${_picked.length}', style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
          const Spacer(),
          _batchBtn('移出', () => _removePicked(scheme)),
          const SizedBox(width: 6),
          _batchBtn('移入', () => _movePicked(scheme), primary: true),
        ],
      ),
    );
  }

  Widget _batchBtn(String label, VoidCallback onTap, {bool primary = false}) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: _picked.isEmpty ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: primary ? scheme.primary.withValues(alpha: _picked.isEmpty ? 0.06 : 0.16) : null,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            color: _picked.isEmpty
                ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
                : (primary ? scheme.primary : scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }

  Future<void> _removePicked(ColorScheme scheme) async {
    final n = await widget.store.removeManyFromGroup(_picked.toList(), _group);
    if (!mounted) return;
    setState(() {
      _picked.clear();
    });
    _toast('已移出 $n 只');
  }

  Future<void> _movePicked(ColorScheme scheme) async {
    final target = await _pickGroup(title: '移入分组', exclude: _group);
    if (target == null) return;
    final n = await widget.store.addManyToGroup(_picked.toList(), target.id);
    if (!mounted) return;
    setState(() {
      _picked.clear();
    });
    _toast('已把 $n 只移入「${target.name}」');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  // ---------------------------------------------------------------- 分组操作

  /// 右上角齿轮：分组总菜单。
  Future<void> _groupMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _Sheet(
        title: '分组管理',
        items: const [
          ('new', '新建分组', Icons.add_rounded),
          ('rename', '重命名当前分组', Icons.drive_file_rename_outline_rounded),
          ('sort', '调整分组顺序', Icons.swap_vert_rounded),
          ('delete', '删除当前分组', Icons.delete_outline_rounded),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'new':
        await _newGroup();
      case 'rename':
        final g = _currentGroup();
        if (g != null) await _renameGroup(g);
      case 'sort':
        await _sortGroups();
      case 'delete':
        final g = _currentGroup();
        if (g != null) await _deleteGroup(g);
    }
  }

  /// 长按某个分组：只对该分组操作。
  Future<void> _groupActions(WatchGroup g) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _Sheet(
        title: g.name,
        items: const [
          ('rename', '重命名', Icons.drive_file_rename_outline_rounded),
          ('sort', '调整顺序', Icons.swap_vert_rounded),
          ('delete', '删除分组', Icons.delete_outline_rounded),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'rename':
        await _renameGroup(g);
      case 'sort':
        await _sortGroups();
      case 'delete':
        await _deleteGroup(g);
    }
  }

  WatchGroup? _currentGroup() {
    for (final g in widget.store.groups) {
      if (g.id == _group) return g;
    }
    return widget.store.groups.isEmpty ? null : widget.store.groups.first;
  }

  Future<void> _newGroup() async {
    final name = await _promptText(title: '新建分组', hint: '分组名称');
    if (name == null || name.trim().isEmpty) return;
    final g = await widget.store.createGroup(name.trim());
    if (!mounted) return;
    setState(() => _group = g.id);
  }

  Future<void> _renameGroup(WatchGroup g) async {
    final name = await _promptText(title: '重命名分组', hint: '分组名称', initial: g.name);
    if (name == null || name.trim().isEmpty) return;
    await widget.store.renameGroup(g.id, name.trim());
  }

  Future<void> _deleteGroup(WatchGroup g) async {
    if (widget.store.groups.length <= 1) {
      _toast('至少要保留一个分组');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除分组', style: TextStyle(fontSize: 15)),
        content: Text('删除「${g.name}」？\n组内股票会从该分组移除，其他分组里的不受影响。', style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.store.deleteGroup(g.id);
  }

  /// 拖动排序分组。
  Future<void> _sortGroups() async {
    if (widget.store.groups.length < 2) {
      _toast('至少两个分组才能排序');
      return;
    }
    final ordered = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _GroupSortSheet(groups: widget.store.groups),
    );
    if (ordered == null) return;
    await widget.store.reorderGroups(ordered);
  }

  /// 选一个分组（批量移入用）。
  Future<WatchGroup?> _pickGroup({required String title, String? exclude}) async {
    final options = [
      for (final g in widget.store.groups)
        if (g.id != exclude) g,
    ];
    if (options.isEmpty) {
      _toast('没有其他分组，先新建一个');
      return null;
    }
    final id = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _Sheet(title: title, items: [for (final g in options) (g.id, g.name, Icons.folder_outlined)]),
    );
    if (id == null) return null;
    for (final g in options) {
      if (g.id == id) return g;
    }
    return null;
  }

  Future<String?> _promptText({required String title, required String hint, String? initial}) {
    final controller = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 15)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(hintText: hint, isDense: true),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('确定')),
        ],
      ),
    );
  }
}

/// 通用底部菜单。
class _Sheet extends StatelessWidget {
  const _Sheet({required this.title, required this.items});

  final String title;

  /// (value, label, icon)
  final List<(String, String, IconData)> items;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(color: scheme.outlineVariant, borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                title,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface),
              ),
            ),
          ),
          for (final it in items)
            ListTile(
              dense: true,
              leading: Icon(it.$3, size: 18, color: scheme.primary),
              title: Text(it.$2, style: TextStyle(fontSize: 13.5, color: scheme.onSurface)),
              onTap: () => Navigator.of(context).pop(it.$1),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// 分组排序：拖动调整，确定时返回新顺序。
class _GroupSortSheet extends StatefulWidget {
  const _GroupSortSheet({required this.groups});

  final List<WatchGroup> groups;

  @override
  State<_GroupSortSheet> createState() => _GroupSortSheetState();
}

class _GroupSortSheetState extends State<_GroupSortSheet> {
  late final List<WatchGroup> _list = List.of(widget.groups);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: MediaQuery.sizeOf(context).height * 0.5,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(color: scheme.outlineVariant, borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Text(
                  '拖动调整分组顺序',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop([for (final g in _list) g.id]),
                  child: const Text('完成'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              itemCount: _list.length,
              // Flutter 3.41+ 用 onReorderItem：新回调已经处理过「先移除后插入」的索引偏移，
              // 不要再自己 newIndex--，否则会差一位。
              onReorderItem: (oldIndex, newIndex) {
                setState(() {
                  final item = _list.removeAt(oldIndex);
                  _list.insert(newIndex, item);
                });
              },
              itemBuilder: (context, i) {
                final g = _list[i];
                return ListTile(
                  key: ValueKey(g.id),
                  dense: true,
                  leading: Icon(Icons.drag_handle_rounded, size: 18, color: scheme.onSurfaceVariant),
                  title: Text(g.name, style: TextStyle(fontSize: 13.5, color: scheme.onSurface)),
                  trailing: Text(
                    '${widget.groups.indexWhere((x) => x.id == g.id) + 1}',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
