/// 自选股与分组。
///
/// 与 Eta 的结构对齐：一只股票可以属于多个分组，分组是用户自建的标签集合。
/// 存储走 `AppPaths.support/stock_watchlist.json`，不依赖数据库，也不引入新依赖。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'dart:io';

import '../../core/paths.dart';

/// 一个分组。
class WatchGroup {
  WatchGroup({required this.id, required this.name});

  final String id;
  String name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  static WatchGroup fromJson(Map<String, dynamic> j) => WatchGroup(id: '${j['id'] ?? ''}', name: '${j['name'] ?? ''}');
}

/// 一只自选股。
class WatchItem {
  WatchItem({required this.code, required this.name, this.groups = const <String>[], this.sort = 0});

  /// 完整代码，如 `sz300274`
  final String code;
  final String name;
  final List<String> groups;
  final int sort;

  WatchItem copyWith({String? name, List<String>? groups, int? sort}) =>
      WatchItem(code: code, name: name ?? this.name, groups: groups ?? this.groups, sort: sort ?? this.sort);

  Map<String, dynamic> toJson() => {'code': code, 'name': name, 'groups': groups, 'sort': sort};

  static WatchItem fromJson(Map<String, dynamic> j) => WatchItem(
    code: '${j['code'] ?? ''}',
    name: '${j['name'] ?? ''}',
    groups: [for (final g in (j['groups'] as List? ?? const [])) '$g'],
    sort: (j['sort'] as num?)?.toInt() ?? 0,
  );
}

/// 自选股仓库。全局单例，面板与设置页共用。
class WatchlistStore extends ChangeNotifier {
  WatchlistStore._();

  static final WatchlistStore instance = WatchlistStore._();

  static const _kGroups = 'stock_watch_groups';
  static const _kItems = 'stock_watch_items';

  List<WatchGroup> _groups = [];
  List<WatchItem> _items = [];
  bool _loaded = false;

  List<WatchGroup> get groups => List.unmodifiable(_groups);
  List<WatchItem> get items => List.unmodifiable(_items);
  bool get loaded => _loaded;

  /// 默认分组，首次使用时创建。
  String get defaultGroupId => _groups.isEmpty ? '' : _groups.first.id;

  static const _fileName = 'stock_watchlist.json';

  File _file() => File('${AppPaths.support.path}/$_fileName');

  Future<void> load() async {
    if (_loaded) return;
    try {
      final f = _file();
      if (await f.exists()) {
        final raw = await f.readAsString();
        if (raw.trim().isNotEmpty) {
          final j = jsonDecode(raw);
          if (j is Map) {
            final g = j[_kGroups];
            if (g is List) {
              _groups = [
                for (final e in g)
                  if (e is Map) WatchGroup.fromJson(e.cast<String, dynamic>()),
              ];
            }
            final i = j[_kItems];
            if (i is List) {
              _items = [
                for (final e in i)
                  if (e is Map) WatchItem.fromJson(e.cast<String, dynamic>()),
              ];
            }
          }
        }
      }
    } catch (_) {
      _items = [];
    }
    // 没有分组时建一个「全部」，保证有落脚点。
    if (_groups.isEmpty) {
      _groups = [WatchGroup(id: 'all', name: '全部')];
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final f = _file();
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          _kGroups: [for (final g in _groups) g.toJson()],
          _kItems: [for (final i in _items) i.toJson()],
        }),
        flush: true,
      );
      await tmp.rename(f.path);
    } catch (_) {
      // 写失败只影响持久化，本次会话内的改动仍然有效
    }
  }

  /// 某个分组下的股票。
  List<WatchItem> inGroup(String groupId) {
    if (groupId.isEmpty) return items;
    return [
      for (final i in _items)
        if (i.groups.contains(groupId)) i,
    ];
  }

  bool contains(String code) => _items.any((e) => e.code == code);

  Future<void> add(String code, String name, {String? groupId}) async {
    await load();
    final gid = groupId ?? defaultGroupId;
    final idx = _items.indexWhere((e) => e.code == code);
    if (idx >= 0) {
      // 已有这只：只补分组
      final cur = _items[idx];
      if (!cur.groups.contains(gid)) {
        _items[idx] = cur.copyWith(groups: [...cur.groups, gid]);
      }
    } else {
      _items = [
        ..._items,
        WatchItem(code: code, name: name, groups: gid.isEmpty ? [] : [gid], sort: _items.length),
      ];
    }
    notifyListeners();
    await _persist();
  }

  Future<void> remove(String code) async {
    await load();
    _items = [
      for (final e in _items)
        if (e.code != code) e,
    ];
    notifyListeners();
    await _persist();
  }

  /// 从某个分组移出（股票本身可能还在别的分组）。
  Future<void> removeFromGroup(String code, String groupId) async {
    await load();
    final idx = _items.indexWhere((e) => e.code == code);
    if (idx < 0) return;
    final cur = _items[idx];
    final next = [
      for (final g in cur.groups)
        if (g != groupId) g,
    ];
    if (next.isEmpty) {
      _items = [
        for (final e in _items)
          if (e.code != code) e,
      ];
    } else {
      _items = [..._items]..[idx] = cur.copyWith(groups: next);
    }
    notifyListeners();
    await _persist();
  }

  Future<WatchGroup> createGroup(String name) async {
    await load();
    final g = WatchGroup(id: 'g${DateTime.now().millisecondsSinceEpoch}', name: name.trim());
    _groups = [..._groups, g];
    notifyListeners();
    await _persist();
    return g;
  }

  Future<void> renameGroup(String id, String name) async {
    await load();
    _groups = [for (final g in _groups) g.id == id ? (WatchGroup(id: g.id, name: name.trim())) : g];
    notifyListeners();
    await _persist();
  }

  Future<void> deleteGroup(String id) async {
    await load();
    if (_groups.length <= 1) return; // 至少留一个
    _groups = [
      for (final g in _groups)
        if (g.id != id) g,
    ];
    _items = [
      for (final i in _items)
        if (i.groups.contains(id))
          i.copyWith(
            groups: [
              for (final g in i.groups)
                if (g != id) g,
            ],
          )
        else
          i,
    ];
    _items = [
      for (final i in _items)
        if (i.groups.isNotEmpty) i,
    ];
    notifyListeners();
    await _persist();
  }

  /// 调整顺序（拖动排序用）。
  Future<void> reorder(List<String> orderedCodes) async {
    await load();
    final map = {for (final i in _items) i.code: i};
    final next = <WatchItem>[];
    for (var i = 0; i < orderedCodes.length; i++) {
      final it = map[orderedCodes[i]];
      if (it != null) next.add(it.copyWith(sort: i));
    }
    _items = next;
    notifyListeners();
    await _persist();
  }
}
