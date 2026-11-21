import 'dart:convert';
import 'dart:io';

import '../core/paths.dart';
import '../core/util.dart';
import 'sub_agent.dart';

/// 子智能体配置的持久化。
///
/// 放在 support 目录的 `sub_agents.json`，和 settings.json 同级。MewHub 没有
/// shared_preferences，全部走文件；文件坏了就当没有，不阻塞启动。
class SubAgentStore {
  static const _fileName = 'sub_agents.json';

  /// 「已经装过内置条目」的标记。用户删掉某个内置子智能体后，下次启动不能
  /// 又给他加回来，否则等于删不掉。
  static const _seedFlag = '.sub_agents_seeded';

  static List<SubAgent>? _cache;

  static File _file() => File('${AppPaths.support.path}/$_fileName');
  static File _flag() => File('${AppPaths.support.path}/$_seedFlag');

  static Future<List<SubAgent>> load() async {
    final hit = _cache;
    if (hit != null) return hit;
    final file = _file();
    var agents = <SubAgent>[];
    var exists = false;
    try {
      if (await file.exists()) {
        exists = true;
        final raw = await file.readAsString();
        final decoded = tryJsonDecode(raw);
        if (decoded is Map) {
          agents = asList(decoded['agents']).map((e) => SubAgent.fromJson(asMap(e))).toList();
        }
      }
    } catch (_) {
      // 解析失败：保留原文件（用户还能手工救），内存里当空处理。
      agents = [];
      exists = false;
    }
    if (!exists && !await _flag().exists()) {
      agents = builtinSubAgents.map((e) => SubAgent.fromJson(e.toJson())).toList();
      await save(agents);
      try {
        await _flag().writeAsString(DateTime.now().toIso8601String());
      } catch (_) {}
    }
    _cache = agents;
    return agents;
  }

  static Future<void> save(List<SubAgent> agents) async {
    _cache = List<SubAgent>.from(agents);
    try {
      final file = _file();
      await file.parent.create(recursive: true);
      // tmp 名必须唯一：并发保存时同名 .tmp 会互相覆盖，rename 可能拿到半个文件。
      final tmp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'agents': [for (final a in agents) a.toJson()],
        }),
        flush: true,
      );
      await tmp.rename(file.path);
    } catch (_) {
      // 写失败只影响下次启动，本次会话仍可用。
    }
  }

  /// 供测试与「恢复默认」用。
  static void resetCache() => _cache = null;
}
