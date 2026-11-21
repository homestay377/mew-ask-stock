import 'dart:convert';

import '../core/util.dart';
import '../tools/tool.dart';
import 'sub_agent.dart';
import 'sub_agent_runner.dart';
import 'tool_run_context.dart';

/// 子智能体相关的工具。没有可用的子智能体时返回空列表，模型也就看不到它们。
List<AppTool> buildSubAgentTools({required List<SubAgent> agents}) {
  final usable = agents.where((a) => a.usable).toList();
  if (usable.isEmpty) return <AppTool>[];
  return [_dispatchTool(usable)];
}

class _Assignment {
  _Assignment({required this.agent, required this.task, required this.deferred});
  final SubAgent agent;
  final String task;
  final bool deferred;
}

String _short(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';

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
              'agent': strProp('子智能体名称，必须是：${names.join('、')}'),
              'task': strProp('交给它的具体任务，必须包含足够上下文：哪只股票、哪个周期、要回答什么问题'),
              'wait_for_others': {'type': 'boolean', 'description': '是否等同批其他任务完成后再执行。默认 false（立刻并行开工）；复核、出方案类应设为 true'},
            },
            'required': ['agent', 'task'],
          },
        },
      },
      required: ['tool_title', 'assignments'],
    ),
    promptHint:
        '你可以用 `dispatch_subagents` 把互相独立的工作（不同股票、不同角度、先取数再审查）交给子智能体，'
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
      final byName = {for (final a in agents) a.name: a};
      final unknown = <String>[];
      final planned = <_Assignment>[];
      for (final row in rows) {
        final m = asMap(row);
        final name = asStr(m['agent']).trim();
        final task = asStr(m['task']).trim();
        final agent = byName[name];
        if (agent == null) {
          unknown.add(name.isEmpty ? '（空名称）' : name);
          continue;
        }
        if (task.isEmpty) {
          unknown.add('$name（任务描述为空）');
          continue;
        }
        if (planned.length >= 6) break;
        planned.add(_Assignment(agent: agent, task: task, deferred: m['wait_for_others'] == true));
      }
      if (planned.isEmpty) {
        return jsonEncode({'error': '没有一个任务能分派', 'unknown_agents': unknown, 'available': names});
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
        ),
      );

      final results = <SubAgentResult>[];
      final immediate = planned.where((e) => !e.deferred).toList();
      final deferred = planned.where((e) => e.deferred).toList();
      if (immediate.isNotEmpty) {
        results.addAll(await Future.wait([for (final a in immediate) runner.run(a.agent, a.task)]));
      }
      if (deferred.isNotEmpty && !ctx.cancel.isCancelled) {
        final brief = [
          for (final r in results)
            if (r.output.trim().isNotEmpty) '${r.agent}：${_short(r.output.trim(), 1200)}',
        ].join('\n\n');
        for (final a in deferred) {
          if (ctx.cancel.isCancelled) break;
          results.add(await runner.run(a.agent, a.task, extraContext: brief));
        }
      }

      final payload = <String, dynamic>{
        'title': title.isEmpty ? '子智能体分派' : title,
        'ok': results.isNotEmpty && results.every((r) => r.ok),
        'results': [for (final r in results) r.toJson()],
        if (unknown.isNotEmpty) 'unknown_agents': unknown,
        if (ctx.cancel.isCancelled) 'cancelled': true,
        'hint': '这些是子智能体交回的素材：数字照抄，结论由你自己判断并整合；不要把它们当成最终答案直接转述。',
      };
      return jsonEncode(payload);
    },
  );
}
