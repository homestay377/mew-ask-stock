import 'dart:async';

import '../core/util.dart';
import 'sub_agent.dart';
import 'sub_agent_runner.dart';

/// 团队共享任务板的单个任务状态。
enum TeamTaskStatus { pending, running, done, failed, skipped }

/// 任务板上的一条任务。
///
/// [id] 是短 id（t1、t2…），[dependsOn] 只能引用排在它前面的任务。
/// 这套语义对齐清水 1.4.2 的 `add_team_tasks` / `depends_on` 设计：
/// 前置失败时依赖它的任务自动跳过，避免在错误结果上继续烧 token。
class TeamTask {
  TeamTask({required this.id, required this.agentName, required this.task, this.dependsOn = const []});

  final String id;
  final String agentName;
  final String task;
  final List<String> dependsOn;

  TeamTaskStatus status = TeamTaskStatus.pending;
  SubAgentResult? result;
  String? error;
  int elapsedMs = 0;

  bool get isTerminal =>
      status == TeamTaskStatus.done || status == TeamTaskStatus.failed || status == TeamTaskStatus.skipped;

  Map<String, dynamic> toJson() => {
    'id': id,
    'agent': agentName,
    'status': status.name,
    'depends_on': dependsOn,
    if (result != null) 'ok': result!.ok,
    if (result != null) 'output': result!.output,
    if (error != null) 'error': error,
    'ms': elapsedMs,
    if (result != null) 'steps': [for (final s in result!.steps) s.toJson()],
  };
}

/// 依赖产出注入下游任务时的预算（对齐清水 1.4.2 的数字）。
const dependencyResultPerTaskLimit = 2500;
const dependencyResultBudget = 8000;

/// 一次分派对应的一张任务板。
class TeamBoard {
  TeamBoard({required this.title, required this.tasks});

  final String title;
  final List<TeamTask> tasks;
  bool closed = false;

  TeamTask? byId(String id) {
    for (final t in tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// 把已完成的前置任务产出拼成给下游用的上下文，带总预算。
  String briefFor(TeamTask task) {
    if (task.dependsOn.isEmpty) return '';
    final parts = <String>[];
    var budget = dependencyResultBudget;
    for (final depId in task.dependsOn) {
      if (budget <= 0) break;
      final dep = byId(depId);
      if (dep == null || dep.result == null) continue;
      final text = dep.result!.output.trim();
      if (text.isEmpty) continue;
      final take = text.length > dependencyResultPerTaskLimit ? text.substring(0, dependencyResultPerTaskLimit) : text;
      if (take.length > budget) continue;
      budget -= take.length;
      parts.add('【$depId · ${dep.agentName}】\n$take');
    }
    return parts.join('\n\n');
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    'closed': closed,
    'tasks': [for (final t in tasks) t.toJson()],
    'done': tasks.where((t) => t.status == TeamTaskStatus.done).length,
    'failed': tasks.where((t) => t.status == TeamTaskStatus.failed).length,
    'skipped': tasks.where((t) => t.status == TeamTaskStatus.skipped).length,
  };
}

/// 按依赖图执行任务板。
///
/// 规则：
/// 1. 依赖全部 `done` 的任务立刻并行开工；
/// 2. 依赖里有 `failed` 或 `skipped` 的任务标 `skipped`，不再消耗 token；
/// 3. 没有任何任务可以推进时跳出（有环或引用了不存在的 id）。
Future<void> runTeamBoard(
  TeamBoard board,
  SubAgentRunner runner, {
  required bool Function() isCancelled,
  void Function(String)? onProgress,
}) async {
  var guard = 0;
  while (true) {
    if (isCancelled()) break;
    if (++guard > 64) break;

    // 1) 先把"前置已经废了"的任务判死，避免它们一直挂着。
    var changed = true;
    while (changed) {
      changed = false;
      for (final t in board.tasks) {
        if (t.status != TeamTaskStatus.pending) continue;
        var blocked = false;
        String? because;
        for (final depId in t.dependsOn) {
          final dep = board.byId(depId);
          if (dep == null) {
            blocked = true;
            because = '依赖的 $depId 不存在';
            break;
          }
          if (dep.status == TeamTaskStatus.failed) {
            blocked = true;
            because = '前置 $depId 失败';
            break;
          }
          if (dep.status == TeamTaskStatus.skipped) {
            blocked = true;
            because = '前置 $depId 被跳过';
            break;
          }
        }
        if (blocked) {
          t.status = TeamTaskStatus.skipped;
          t.error = because;
          changed = true;
          onProgress?.call('${t.id} 跳过：$because');
        }
      }
    }

    // 2) 找出这一批可以开工的任务。
    final ready = <TeamTask>[];
    for (final t in board.tasks) {
      if (t.status != TeamTaskStatus.pending) continue;
      var ok = true;
      for (final depId in t.dependsOn) {
        final dep = board.byId(depId);
        if (dep == null || dep.status != TeamTaskStatus.done) {
          ok = false;
          break;
        }
      }
      if (ok) ready.add(t);
    }
    if (ready.isEmpty) {
      // 还有 pending 但没人能跑 → 有环或依赖不满足，判死避免无限等
      for (final t in board.tasks) {
        if (t.status == TeamTaskStatus.pending) {
          t.status = TeamTaskStatus.skipped;
          t.error = '依赖无法满足（可能有环）';
        }
      }
      break;
    }

    await Future.wait([for (final t in ready) _runOne(t, board, runner, onProgress: onProgress)]);
  }
}

Future<void> _runOne(TeamTask t, TeamBoard board, SubAgentRunner runner, {void Function(String)? onProgress}) async {
  t.status = TeamTaskStatus.running;
  onProgress?.call('${t.id} · ${t.agentName} 开工');
  final byName = <String, SubAgent>{};
  for (final a in runner.peers) {
    byName[a.name] = a;
  }
  final agent = byName[t.agentName];
  if (agent == null) {
    t.status = TeamTaskStatus.failed;
    t.error = '没有这个子智能体：${t.agentName}';
    return;
  }
  final sw = Stopwatch()..start();
  try {
    final r = await runner.run(agent, t.task, extraContext: board.briefFor(t));
    t.result = r;
    t.elapsedMs = sw.elapsedMilliseconds;
    if (r.ok) {
      t.status = TeamTaskStatus.done;
    } else {
      t.status = TeamTaskStatus.failed;
      t.error = r.error;
    }
  } on Object catch (e) {
    t.elapsedMs = sw.elapsedMilliseconds;
    t.status = TeamTaskStatus.failed;
    t.error = '$e';
  }
  onProgress?.call('${t.id} · ${t.agentName} ${t.status.name}');
}

/// 从模型给的 assignments 里解析出任务板。
///
/// 兼容没有 `task_id` 的老写法：自动补 t1…tN，`wait_for_others: true` 转成
/// "依赖全部前面的任务"，保证旧提示行为不至于直接失效。
({List<TeamTask> tasks, List<String> problems}) parseAssignments(
  List<dynamic> rows,
  List<SubAgent> agents, {
  int maxTasks = 8,
  Set<String> knownIds = const {},
}) {
  final byName = {for (final a in agents) a.name: a};
  final problems = <String>[];
  final tasks = <TeamTask>[];
  final seenIds = <String>{};
  for (var i = 0; i < rows.length; i++) {
    if (tasks.length >= maxTasks) {
      problems.add('超过 $maxTasks 条上限，后面 ${rows.length - i} 条被忽略');
      break;
    }
    final m = asMap(rows[i]);
    final name = asStr(m['agent']).trim();
    final text = asStr(m['task']).trim();
    if (name.isEmpty) {
      problems.add('第 ${i + 1} 条：agent 为空');
      continue;
    }
    if (byName[name] == null) {
      problems.add('第 ${i + 1} 条：没有子智能体「$name」');
      continue;
    }
    if (text.isEmpty) {
      problems.add('$name（第 ${i + 1} 条）：task 为空');
      continue;
    }
    var id = asStr(m['task_id']).trim();
    if (id.isEmpty) id = 't${i + 1}';
    if (id.length > 12) id = id.substring(0, 12);
    if (!seenIds.add(id)) {
      problems.add('任务 id 重复：$id，已改用 t${i + 1}');
      id = 't${i + 1}';
      seenIds.add(id);
    }
    final deps = <String>[];
    for (final d in asList(m['depends_on'])) {
      final s = asStr(d).trim();
      if (s.isEmpty) continue;
      deps.add(s);
    }
    // 老写法兼容：wait_for_others=true 且没写依赖 → 依赖前面所有任务
    if (deps.isEmpty && m['wait_for_others'] == true && tasks.isNotEmpty) {
      deps.addAll(tasks.map((t) => t.id));
    }
    tasks.add(TeamTask(id: id, agentName: name, task: text, dependsOn: deps));
  }
  // 依赖只能引用排在前面的任务
  final order = {for (var i = 0; i < tasks.length; i++) tasks[i].id: i};
  for (final t in tasks) {
    for (final d in t.dependsOn) {
      if (knownIds.contains(d)) continue;
      final at = order[d];
      if (at == null) {
        problems.add('${t.id} 依赖的 $d 不存在');
      } else if (at >= order[t.id]!) {
        problems.add('${t.id} 依赖了排在它后面的 $d（只能引用前面的任务）');
      }
    }
  }
  return (tasks: tasks, problems: problems);
}
