/// 面板内的搜索浮层：点右上角放大镜出现，选一只股票即切过去。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../stock/stock_search.dart';

/// 展示搜索浮层，返回选中的股票；取消返回 null。
Future<StockHit?> showStockSearch(BuildContext context, Future<List<StockHit>> Function(String) search) {
  return showModalBottomSheet<StockHit>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _SearchSheet(search: search),
  );
}

class _SearchSheet extends StatefulWidget {
  const _SearchSheet({required this.search});

  final Future<List<StockHit>> Function(String) search;

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  List<StockHit> _hits = const [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    if (v.trim().isEmpty) {
      setState(() {
        _hits = const [];
        _error = null;
      });
      return;
    }
    // 300ms 防抖，避免每输入一个字就打一次接口
    _debounce = Timer(const Duration(milliseconds: 300), () => _run(v));
  }

  Future<void> _run(String kw) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.search(kw);
      if (!mounted) return;
      setState(() {
        _hits = r;
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
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
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
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                autofocus: true,
                onChanged: _onChanged,
                style: TextStyle(fontSize: 14, color: scheme.onSurface),
                decoration: InputDecoration(
                  hintText: '搜索股票名称、代码或拼音',
                  prefixIcon: Icon(Icons.search_rounded, size: 18, color: scheme.onSurfaceVariant),
                  isDense: true,
                  filled: true,
                  fillColor: scheme.surfaceContainerHigh,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
            ),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!, style: TextStyle(color: scheme.error, fontSize: 12)),
              ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _hits.length,
                itemBuilder: (context, i) {
                  final h = _hits[i];
                  return ListTile(
                    dense: true,
                    title: Text(h.name, style: TextStyle(fontSize: 14, color: scheme.onSurface)),
                    subtitle: Text(h.code, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                    trailing: Text(
                      h.pinyin.toUpperCase(),
                      style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
                    ),
                    onTap: () => Navigator.of(context).pop(h),
                  );
                },
              ),
            ),
            if (_hits.isEmpty && !_loading && _controller.text.trim().isNotEmpty && _error == null)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text('没有找到匹配的 A 股', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
