/// 面板内的自选股抽屉：从展开态面板左侧滑出，点一只即切过去。
library;

import 'package:flutter/material.dart';

import '../../stock/watchlist_store.dart';

/// 一个可展开的左侧抽屉层，覆盖在 K 线区上。
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

  @override
  void initState() {
    super.initState();
    _group = widget.store.groups.isEmpty ? '' : widget.store.groups.first.id;
    widget.store.addListener(_onStore);
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStore);
    super.dispose();
  }

  void _onStore() {
    if (mounted) setState(() {});
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
            onTap: () {}, // 吃掉点击，避免点抽屉内部也关闭
            child: Container(
              width: 168,
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: const BorderRadius.horizontal(right: Radius.circular(14)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 6, 4),
                    child: Row(
                      children: [
                        Text(
                          '自选',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurface),
                        ),
                        const Spacer(),
                        InkWell(
                          onTap: widget.onClose,
                          child: Icon(Icons.close_rounded, size: 16, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  // 分组横条
                  SizedBox(
                    height: 26,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        for (final g in widget.store.groups)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: GestureDetector(
                              onTap: () => setState(() => _group = g.id),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
                      ],
                    ),
                  ),
                  Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
                  Expanded(
                    child: items.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                '这个分组还没有股票\n用右上角 + 添加',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            itemCount: items.length,
                            itemBuilder: (context, i) {
                              final it = items[i];
                              final sel = it.code == widget.currentCode;
                              return InkWell(
                                onTap: () => widget.onPick(it.code, it.name),
                                onLongPress: () => _confirmRemove(context, it.code, it.name),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                                  color: sel ? scheme.primary.withValues(alpha: 0.08) : null,
                                  child: Row(
                                    children: [
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
                                                color: sel ? scheme.primary : scheme.onSurface,
                                                fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                                              ),
                                            ),
                                            Text(
                                              it.code.replaceFirst(RegExp(r'^(sh|sz|bj)'), ''),
                                              style: TextStyle(fontSize: 9, color: scheme.onSurfaceVariant),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, String code, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移出自选', style: TextStyle(fontSize: 15)),
        content: Text('把 $name 从当前分组移出？', style: TextStyle(fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('移出')),
        ],
      ),
    );
    if (ok == true) {
      await widget.store.removeFromGroup(code, _group);
    }
  }
}
