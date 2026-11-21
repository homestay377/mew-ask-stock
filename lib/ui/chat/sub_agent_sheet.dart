import 'dart:convert';

import 'package:flutter/material.dart';

import '../../agents/sub_agent.dart';
import '../../agents/sub_agent_store.dart';
import '../../ai/message.dart';
import '../../core/i18n.dart';
import '../../core/util.dart';
import '../widgets/common.dart';

/// 「智能体团队」面板：这一轮谁在干活、跑到哪一步、交回了什么。
///
/// 数据全部来自本机：成员读 sub_agents.json，任务读当前会话里
/// dispatch_subagents / discuss_subagents 的 ToolPart。
Future<void> showSubAgentTeamSheet(BuildContext context, {required List<Part> Function() liveParts}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _TeamSheet(liveParts: liveParts),
  );
}

class _AgentOutput {
  const _AgentOutput({required this.agent, required this.ok, required this.detail, required this.text});
  final String agent;
  final bool ok;
  final String detail;
  final String text;
}

class _TaskEntry {
  const _TaskEntry({required this.title, required this.ok, required this.outputs});
  final String title;
  final bool ok;
  final List<_AgentOutput> outputs;
}

class _TeamSheet extends StatefulWidget {
  const _TeamSheet({required this.liveParts});
  final List<Part> Function() liveParts;

  @override
  State<_TeamSheet> createState() => _TeamSheetState();
}

class _TeamSheetState extends State<_TeamSheet> {
  List<SubAgent>? _agents;

  @override
  void initState() {
    super.initState();
    SubAgentStore.load().then((v) {
      if (mounted) setState(() => _agents = v);
    });
  }

  /// 当前会话里所有跑过（或正在跑）的分派/讨论工具。
  List<ToolPart> get _parts => [
    for (final p in widget.liveParts())
      if (p is ToolPart && (p.name == 'dispatch_subagents' || p.name == 'discuss_subagents')) p,
  ];

  /// 正在干活的成员：从进度行里取最后一行。
  Map<String, String> get _running {
    final out = <String, String>{};
    for (final p in _parts) {
      if (p.output != null) continue;
      final lines = (p.meta?['progress'] as List?)?.whereType<String>().toList() ?? const [];
      if (lines.isEmpty) continue;
      final line = lines.last;
      final name = line.split(' · ').first.trim();
      if (name.isNotEmpty) out[name] = line;
    }
    return out;
  }

  List<_TaskEntry> get _tasks {
    final out = <_TaskEntry>[];
    for (final p in _parts) {
      final raw = p.output;
      if (raw == null) continue;
      final j = tryJsonDecode(raw);
      if (j is! Map) continue;
      final title = asStr(j['title']).trim().isEmpty ? asStr(j['topic']).trim() : asStr(j['title']).trim();
      final outs = <_AgentOutput>[];
      final results = j['results'];
      if (results is List) {
        for (final e in results) {
          if (e is! Map) continue;
          final m = asMap(e);
          outs.add(
            _AgentOutput(agent: asStr(m['agent']), ok: m['ok'] == true, detail: _detail(m), text: asStr(m['output'])),
          );
        }
      }
      final turns = j['turns'];
      if (turns is List) {
        for (final e in turns) {
          if (e is! Map) continue;
          final m = asMap(e);
          outs.add(
            _AgentOutput(
              agent: '${t('第', 'R')}${m['round']} · ${asStr(m['agent'])}',
              ok: m['ok'] == true,
              detail: _detail(m),
              text: asStr(m['output']),
            ),
          );
        }
      }
      if (outs.isEmpty && j['error'] != null) {
        outs.add(_AgentOutput(agent: t('工具', 'tool'), ok: false, detail: '', text: asStr(j['error'])));
      }
      out.add(
        _TaskEntry(title: title.isEmpty ? t('未命名任务', 'Untitled task') : title, ok: j['ok'] == true, outputs: outs),
      );
    }
    return out;
  }

  String _detail(Map<String, dynamic> m) {
    final steps = m['steps'];
    final n = steps is List ? steps.length : 0;
    final ms = m['ms'] is num ? (m['ms'] as num).toInt() : 0;
    final tokens = m['tokens'];
    var tok = 0;
    if (tokens is Map) {
      final i = tokens['input'];
      final o = tokens['output'];
      tok = (i is num ? i.toInt() : 0) + (o is num ? o.toInt() : 0);
    }
    return [
      if (n > 0) '$n ${t('步', 'steps')}',
      if (tok > 0) formatTokens(tok),
      if (ms > 0) '${(ms / 1000).toStringAsFixed(1)}s',
    ].join(' · ');
  }

  /// 每个成员各自的工具调用记录（来自最近一次任务里的 steps）。
  List<({String agent, String tool, bool ok, int ms})> _calls(String agent) {
    for (final p in _parts.reversed) {
      final raw = p.output;
      if (raw == null) continue;
      final j = tryJsonDecode(raw);
      if (j is! Map) continue;
      for (final key in const ['results', 'turns']) {
        final rows = j[key];
        if (rows is! List) continue;
        for (final e in rows) {
          if (e is! Map) continue;
          final m = asMap(e);
          if (asStr(m['agent']) != agent) continue;
          final steps = m['steps'];
          if (steps is! List) continue;
          return [
            for (final s in steps)
              if (s is Map)
                (
                  agent: agent,
                  tool: asStr(asMap(s)['tool']),
                  ok: asMap(s)['ok'] == true,
                  ms: asMap(s)['ms'] is num ? (asMap(s)['ms'] as num).toInt() : 0,
                ),
          ];
        }
      }
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final agents = _agents;
    final running = _running;
    final tasks = _tasks;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.62,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Row(
            children: [
              IconBadge(Icons.groups_2_outlined, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t('智能体团队', 'Agent team'), style: Theme.of(context).textTheme.titleLarge),
                    Text(
                      t(
                        '主智能体拆任务，子智能体并行干活并自动交接结果',
                        'The lead agent splits the work; sub-agents run in parallel and hand back',
                      ),
                      style: style,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(t('成员', 'Members'), style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _memberCard(
                context,
                name: t('主控', 'Lead'),
                tags: [t('当前会话', 'this chat')],
                status: running.isEmpty ? t('待命', 'idle') : (running.values.first),
              ),
              if (agents != null)
                for (final a in agents)
                  _memberCard(
                    context,
                    name: a.name,
                    tags: [if (a.readOnly) t('只读', 'read-only'), if (!a.enabled) t('已停用', 'disabled')],
                    status: running[a.name] ?? t('待命', 'idle'),
                    calls: _calls(a.name),
                  ),
            ],
          ),
          if (agents == null) const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()),
          const SizedBox(height: 20),
          Row(
            children: [
              Text(t('共享任务', 'Shared tasks'), style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(width: 6),
              Text('${tasks.length}', style: style),
            ],
          ),
          const SizedBox(height: 8),
          if (tasks.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t('还没有共享任务', 'No shared tasks yet')),
                    const SizedBox(height: 6),
                    Text(
                      t(
                        '对主智能体说「用智能体团队分析 300274 日线和 60 分」，它会拆任务、并行分派，并把前置结果交给下游。',
                        'Ask the lead to "analyze 300274 daily and 60m with the team"; it splits, dispatches in parallel and hands results downstream.',
                      ),
                      style: style,
                    ),
                  ],
                ),
              ),
            )
          else
            for (final task in tasks)
              Card(
                clipBehavior: Clip.antiAlias,
                child: ExpansionTile(
                  shape: const Border(),
                  leading: Icon(
                    task.ok ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
                    color: task.ok ? scheme.primary : scheme.error,
                  ),
                  title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${task.outputs.length} ${t('个子智能体', 'agents')}', style: style),
                  children: [
                    for (final o in task.outputs)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  o.ok ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
                                  size: 14,
                                  color: o.ok ? scheme.primary : scheme.error,
                                ),
                                const SizedBox(width: 6),
                                Text(o.agent, style: const TextStyle(fontWeight: FontWeight.w600)),
                                if (o.detail.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(o.detail, style: style, overflow: TextOverflow.ellipsis),
                                  ),
                                ],
                              ],
                            ),
                            if (o.text.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4, left: 20),
                                child: Text(o.text, style: style),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
          const SizedBox(height: 12),
          Text(
            t(
              '依赖任务会在前置完成后自动开工；前置失败时下游自动跳过。点任务可展开产出。',
              'Dependent tasks start after their upstream finishes; downstream is skipped if upstream fails. Tap a task to expand its output.',
            ),
            style: style,
          ),
        ],
      ),
    );
  }

  Widget _memberCard(
    BuildContext context, {
    required String name,
    required List<String> tags,
    required String status,
    List<({String agent, String tool, bool ok, int ms})> calls = const [],
  }) {
    final scheme = Theme.of(context).colorScheme;
    final busy = status != t('待命', 'idle');
    return SizedBox(
      width: 168,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: busy ? scheme.primary : scheme.outlineVariant,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
              ),
              if (tags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 4,
                    children: [
                      for (final tag in tags)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: scheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(tag, style: Theme.of(context).textTheme.labelSmall),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 6),
              Text(status, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
              if (calls.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${calls.length} ${t('次工具调用', 'tool calls')}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 供测试与外部复用：把一份工具输出解析成团队面板的行。
List<({String agent, String detail, bool ok})> parseTeamRows(String json) {
  final j = tryJsonDecode(json);
  if (j is! Map) return const [];
  final out = <({String agent, String detail, bool ok})>[];
  for (final key in const ['results', 'turns']) {
    final rows = j[key];
    if (rows is! List) continue;
    for (final e in rows) {
      if (e is! Map) continue;
      final m = asMap(e);
      out.add((agent: asStr(m['agent']), detail: jsonEncode(m['steps'] ?? const []), ok: m['ok'] == true));
    }
  }
  return out;
}
