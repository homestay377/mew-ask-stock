import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/util.dart';
import '../tools/tool.dart';
import 'sub_agent.dart';
import 'sub_agent_runner.dart';
import 'team_board.dart';
import 'tool_run_context.dart';

/// 子智能体相关的工具。没有可用的子智能体时返回空列表，模型也就看不到它们。
List<AppTool> buildSubAgentTools({required List<SubAgent> agents}) {
  final usable = agents.where((a) => a.usable).toList();
  if (usable.isEmpty) return <AppTool>[];
  return [_dispatchTool(usable), _discussTool(usable), _addTeamTasksTool(usable)];
}

/// 按会话挂载的任务板。`dispatch_subagents` 建板，`add_team_tasks` 追加。
///
/// 只放在内存里：一次对话生成过程结束后板还在，App 重启就清空——
/// 团队任务本来就是一次会话内的事，不值得落盘。
final _boards = <String, TeamBoard>{};

String _keyOf(ToolRunContext ctx) => ctx.sessionKey ?? '__default__';

TeamBoard? currentBoard(ToolRunContext ctx) => _boards[_keyOf(ctx)];

/// 按会话 key 取任务板。给「团队追问」用：ChatController 只拿得到会话 id。
TeamBoard? boardForSession(String? sessionKey) => _boards[sessionKey ?? '__default__'];

/// 会话里是否真的有一张任务板。
bool hasBoardForSession(String? sessionKey) => boardForSession(sessionKey) != null;

/// 任务板注册表：run_id → 活的任务板。
///
/// 界面靠 `ToolPart.meta['run_id']` 精确定位到自己的板。
/// 之前用「取最后一个 value」的全局变量，会话 A 第二次分派后会返回 B 的板
/// （LinkedHashMap 重新赋值不改插入顺序），既会显示错数据，也会停错任务。
final boardRegistry = _BoardRegistry();

class _BoardRegistry extends ChangeNotifier {
  final Map<String, TeamBoard> _byRun = <String, TeamBoard>{};

  TeamBoard? byRunId(String? runId) {
    if (runId == null || runId.isEmpty) return null;
    return _byRun[runId];
  }

  void put(TeamBoard board) {
    _byRun[board.runId] = board;
    // 板自己变化时也要通知界面（ListenableBuilder 监听的是注册表）。
    board.addListener(notifyListeners);
    notifyListeners();
  }

  void remove(String runId) {
    final b = _byRun.remove(runId);
    b?.removeListener(notifyListeners);
    if (b != null) notifyListeners();
  }

  int get length => _byRun.length;
}

AppTool _dispatchTool(List<SubAgent> agents) {
  final names = [for (final a in agents) a.name];
  return AppTool(
    name: 'dispatch_subagents',
    displayName: '子智能体',
    description: '''把任务分派给专职子智能体，等它们完成后把结果拿回来。
同一次调用里的多个任务会【并行】执行：彼此独立的取数、审查、调研请一次性放进同一次 assignments，不要拆成多次调用逐个派发。
依赖别的任务产出才能干的活（复核、出方案），把那条的 wait_for_others 设为 true，它会等前面完成后开工。
子智能体是执行者：任务描述里要写清股票代码、周期、要回答什么，并要求它直接动手。
可用子智能体：
${subAgentCatalog(agents)}''',
    parameters: objectSchema(
      {
        'tool_title': strProp('简短任务标题（5-10 个词），用于在对话里展示这次分派'),
        'assignments': {
          'type': 'array',
          'description': '要分派的任务列表，最多 6 条',
          'items': {
            'type': 'object',
            'properties': {
              'task_id': strProp('任务短 id，例如 t1、t2；留空会自动编号。depends_on 用它来引用'),
              'agent': strProp('子智能体名称，必须是：${names.join('、')}'),
              'task': strProp('交给它的具体任务：目标、验收标准、边界。不要把所有上下文都塞进来，前置产出会自动转交'),
              'depends_on': {
                'type': 'array',
                'items': {'type': 'string'},
                'description': '依赖的前置任务 id 列表，只能引用排在它前面的任务。前置失败时这条会自动跳过',
              },
              'wait_for_others': {'type': 'boolean', 'description': '老写法：等同批全部任务完成后再跑。新任务请优先用 depends_on，它更精确'},
            },
            'required': ['agent', 'task'],
          },
        },
      },
      required: ['tool_title', 'assignments'],
    ),
    promptHint:
        '**默认自己动手。** 只有「确实互相独立、能并行推进」的活才分派：'
        '比如同时看 3 只不同股票、同时查基本面和结构、一边取数一边做资料研究。'
        '看一只股票的走势、回答一个问题、用户说「直接分析」时，不要分派——'
        '你自己有 stock_kline / analyze_chan / stock_levels，直接调比派出去快得多；'
        '子智能体的工具集是主工具的副本，缺什么它们也一样缺。'
        '同一次调用里放多条让它们同时开工。子智能体的返回是素材：最终回答仍由你写，数字照抄、结论由你判断并整合。',
    execute: (args) async {
      final ctx = currentToolRun();
      if (ctx == null) {
        return jsonEncode({'error': '子智能体只能在一次对话生成过程中使用'});
      }
      final title = asStr(args['tool_title']).trim();
      final rows = asList(args['assignments']);
      if (rows.isEmpty) {
        return jsonEncode({'error': 'assignments 为空，至少要分派一个任务'});
      }
      final parsed = parseAssignments(rows, agents);
      if (parsed.tasks.isEmpty) {
        return jsonEncode({'error': '没有一个任务能分派', 'problems': parsed.problems, 'available': names});
      }

      // 子智能体拿到的是同一次生成里的工具表，但永远不含分派工具本身（防套娃）。
      final runner = SubAgentRunner(
        ToolRunContext(
          settings: ctx.settings,
          provider: ctx.provider,
          model: ctx.model,
          tools: ctx.tools,
          cancel: ctx.cancel,
          depth: ctx.depth + 1,
          onProgress: ctx.onProgress,
          onBoardUpdate: ctx.onBoardUpdate,
          sessionKey: ctx.sessionKey,
        ),
        peers: agents,
      );

      final board = TeamBoard(title: title.isEmpty ? '子智能体分派' : title, tasks: parsed.tasks);
      _boards[_keyOf(ctx)] = board;
      boardRegistry.put(board);
      await runTeamBoard(
        board,
        runner,
        isCancelled: () => ctx.cancel.isCancelled,
        onProgress: ctx.onProgress,
        onBoard: ctx.onBoardUpdate,
        globalCancel: ctx.cancel,
        tokenBudget: args['token_budget'] is int ? args['token_budget'] as int : null,
      );
      // 板已经收尾：从注册表摘掉，别让 SubAgentResult 全文一直挂着。
      // 注意不要立即 remove：界面还要靠 run_id 显示终态，等它切换成 output 后再摘。
      _scheduleBoardCleanup(board.runId);

      final payload = <String, dynamic>{
        'title': board.title,
        'ok': board.tasks.every((t) => t.status == TeamTaskStatus.done),
        'board': board.toJson(),
        'results': [
          for (final t in board.tasks)
            if (t.result != null) {'id': t.id, 'status': t.status.name, ...t.result!.toJson()},
        ],
        'problems': parsed.problems,
        if (ctx.cancel.isCancelled) 'cancelled': true,
        'hint':
            '这些是子智能体交回的素材：数字照抄，结论由你自己判断并整合；不要把它们当成最终答案直接转述。'
            '还有活要补时，用 add_team_tasks 追加到同一张任务板，不要重新 dispatch 一遍。',
      };
      return jsonEncode(payload);
    },
  );
}

AppTool _discussTool(List<SubAgent> agents) {
  final names = [for (final a in agents) a.name];
  return AppTool(
    name: 'discuss_subagents',
    displayName: '子智能体讨论',
    description: '''组织几个子智能体围绕一个主题多轮讨论：每一轮每个人都能看到此前所有发言，可以点头、反对、补充。
适合需要多角度权衡、互相挑错的判断，例如「这个位置能不能加仓」「这只票的结构到底成不成立」。
一次最多 4 个参与者，默认 2 轮。讨论是串行进行的，比并行分派慢，只在真正需要交锋时用。
可用子智能体：${subAgentCatalog(agents)}''',
    parameters: objectSchema(
      {
        'topic': strProp('讨论主题。写清股票代码、周期和要回答的具体问题'),
        'agents': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': '参与讨论的子智能体名称；留空表示全部可用。最多取前 4 个',
        },
        'rounds': intProp('轮数 1-5，默认 2'),
      },
      required: ['topic'],
    ),
    promptHint:
        '需要多方权衡、互相挑错时用 `discuss_subagents`；讨论产出的分歧本身就是信息，'
        '你要把「谁同意、谁反对、为什么」写进最终回答，而不是把讨论原样贴出来。',
    execute: (args) async {
      final ctx = currentToolRun();
      if (ctx == null) {
        return jsonEncode({'error': '子智能体只能在一次对话生成过程中使用'});
      }
      final topic = asStr(args['topic']).trim();
      if (topic.isEmpty) {
        return jsonEncode({'error': 'topic 为空，讨论什么？'});
      }
      final wanted = asList(args['agents']).map(asStr).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      final picked = wanted.isEmpty ? agents : agents.where((a) => wanted.contains(a.name)).toList();
      final unknown = [
        for (final n in wanted)
          if (!agents.any((a) => a.name == n)) n,
      ];
      if (picked.isEmpty) {
        return jsonEncode({'error': '没有可参与讨论的子智能体', 'unknown_agents': unknown, 'available': names});
      }
      final chosen = picked.take(4).toList();
      // 先夹再传：原来只夹了回显，模型传 50 就真跑 50 轮 x 4 个 agent。
      final rounds = (args['rounds'] is int ? args['rounds'] as int : 2).clamp(1, 5);
      final runner = SubAgentRunner(
        ToolRunContext(
          settings: ctx.settings,
          provider: ctx.provider,
          model: ctx.model,
          tools: ctx.tools,
          cancel: ctx.cancel,
          depth: ctx.depth + 1,
          onProgress: ctx.onProgress,
        ),
        peers: agents,
      );
      final turns = await runner.discuss(chosen, topic, rounds: rounds);
      return jsonEncode({
        'topic': topic,
        'rounds': rounds,
        'participants': [for (final a in chosen) a.name],
        'ok': turns.isNotEmpty && turns.every((r) => r.ok),
        'turns': [
          for (var i = 0; i < turns.length; i++) {'round': i ~/ chosen.length + 1, ...turns[i].toJson()},
        ],
        if (unknown.isNotEmpty) 'unknown_agents': unknown,
        if (ctx.cancel.isCancelled) 'cancelled': true,
        'hint': '这是讨论记录：分歧点比结论更值钱。最终判断由你自己下，不要把发言原样转给用户。',
      });
    },
  );
}

/// 往当前任务板追加任务。
///
/// 这是清水 1.4.2 里 `add_team_tasks` 的对应实现：**不重新建板**，
/// 新任务并入同一张板继续跑，已有的 id 可以直接被 depends_on 引用。
///
/// 诚实边界：目前追加发生在 dispatch 已经返回之后，不会与仍在执行的子任务
/// 真正并行——那需要把 dispatch 改成后台运行，改动面太大，留到下一步。
AppTool _addTeamTasksTool(List<SubAgent> agents) {
  final names = [for (final a in agents) a.name];
  return AppTool(
    name: 'add_team_tasks',
    displayName: '追加任务',
    description: '''往当前这次分派的任务板追加新任务，不重新建板、不重跑已完成的活。
适合「已经分派一批、发现还缺一件事」的场景；新任务可以直接 depends_on 引用任务板上已有的 id。
如果从来没有分派过，请用 dispatch_subagents 建板。
可用子智能体：
${subAgentCatalog(agents)}''',
    parameters: objectSchema(
      {
        'assignments': {
          'type': 'array',
          'description': '要追加的任务列表，最多 6 条',
          'items': {
            'type': 'object',
            'properties': {
              'task_id': strProp('任务短 id，例如 t7；留空自动编号。不能与已有 id 重复'),
              'agent': strProp('子智能体名称，必须是：${names.join('、')}'),
              'task': strProp('任务内容：目标、验收标准、边界'),
              'depends_on': {
                'type': 'array',
                'items': {'type': 'string'},
                'description': '依赖的任务 id，可以引用任务板上已有的任务，也可以引用本批次前面的任务',
              },
            },
            'required': ['agent', 'task'],
          },
        },
      },
      required: ['assignments'],
    ),
    promptHint:
        '已经分派过、还缺活时用 `add_team_tasks` 追加到同一张任务板；'
        '不要重新 dispatch 一遍，那会把已经做完的活再烧一次 token。',
    execute: (args) async {
      final ctx = currentToolRun();
      if (ctx == null) {
        return jsonEncode({'error': '子智能体只能在一次对话生成过程中使用'});
      }
      final board = currentBoard(ctx);
      if (board == null) {
        return jsonEncode({'error': '团队尚未启动，无法追加任务；请先用 dispatch_subagents 建板'});
      }
      final rows = asList(args['assignments']);
      if (rows.isEmpty) {
        return jsonEncode({'error': 'assignments 为空'});
      }
      // 已存在的 id 不能被覆盖
      final existing = <String>{for (final t in board.tasks) t.id};
      // 分配 id 时必须把「本批已分配的」也算进去，否则板上是 t1/t5/t3 时
      // 追加两条会得到 t4 和 t5——t5 与已有 id 撞车，byId 就解析到错的 task。
      final taken = <String>{...existing};
      final preFixed = <dynamic>[];
      for (final row in rows) {
        final m = Map<String, dynamic>.from(asMap(row));
        var id = asStr(m['task_id']).trim();
        if (id.isEmpty || taken.contains(id)) {
          var n = board.tasks.length + preFixed.length + 1;
          while (taken.contains('t$n')) {
            n++;
          }
          id = 't$n';
        }
        taken.add(id);
        m['task_id'] = id;
        preFixed.add(m);
      }
      final parsed = parseAssignments(preFixed, agents, knownIds: existing);
      if (parsed.tasks.isEmpty) {
        return jsonEncode({'error': '没有一条能追加', 'problems': parsed.problems, 'available': names});
      }
      // 新任务允许依赖板上已有的任务；parseAssignments 只校验同一批次内部顺序，
      // 这里再把「引用了板上不存在的 id」挑出来。
      final bad = <String>[];
      for (final t in parsed.tasks) {
        for (final d in t.dependsOn) {
          if (!existing.contains(d) && !parsed.tasks.any((x) => x.id == d)) bad.add('${t.id} -> $d');
        }
      }
      if (bad.isNotEmpty) {
        return jsonEncode({
          'error': '依赖的任务 id 不存在',
          'problems': bad,
          'board_ids': [for (final t in board.tasks) t.id],
        });
      }
      board.tasks.addAll(parsed.tasks);
      final runner = SubAgentRunner(
        ToolRunContext(
          settings: ctx.settings,
          provider: ctx.provider,
          model: ctx.model,
          tools: ctx.tools,
          cancel: ctx.cancel,
          depth: ctx.depth + 1,
          onProgress: ctx.onProgress,
          onBoardUpdate: ctx.onBoardUpdate,
          sessionKey: ctx.sessionKey,
        ),
        peers: agents,
      );
      await runTeamBoard(
        board,
        runner,
        isCancelled: () => ctx.cancel.isCancelled,
        onProgress: ctx.onProgress,
        onBoard: ctx.onBoardUpdate,
        globalCancel: ctx.cancel,
        tokenBudget: null,
      );
      return jsonEncode({
        'ok': parsed.tasks.every((t) => t.status == TeamTaskStatus.done),
        'added': [for (final t in parsed.tasks) t.toJson()],
        'board': board.toJson(),
        'problems': parsed.problems,
        if (ctx.cancel.isCancelled) 'cancelled': true,
      });
    },
  );
}

/// 延迟清掉已经收尾的板：界面需要一点时间读到终态。
void _scheduleBoardCleanup(String runId) {
  Timer(const Duration(minutes: 2), () => boardRegistry.remove(runId));
}
