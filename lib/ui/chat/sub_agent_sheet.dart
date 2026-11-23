import 'dart:async';

import 'package:flutter/material.dart';

import '../../agents/sub_agent.dart';
import '../../agents/sub_agent_store.dart';
import '../../agents/sub_agent_tools.dart';
import '../../ai/message.dart';
import '../../core/i18n.dart';
import '../../core/util.dart';
import '../widgets/common.dart';

/// 「智能体团队」面板：谁在跑、任务板到哪一步、前置产出交给了谁。
///
/// 数据全部来自本机：成员读 `sub_agents.json`，任务板读当前会话里
/// `dispatch_subagents` / `add_team_tasks` 的 `ToolPart.meta['board']`。
///
/// 关键点：面板打开后会**按帧轮询**刷新（[_tick]），否则它只是一张打开瞬间的快照，
/// 分派跑起来界面毫无反应——那正是之前"假界面"的根因。
Future<void> showSubAgentTeamSheet(
  BuildContext context, {
  required List<Part> Function() liveParts,
  Future<void> Function(String text)? onSubmit,
  Future<String> Function(String text)? onAskTeam,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _TeamSheet(liveParts: liveParts, onSubmit: onSubmit, onAskTeam: onAskTeam),
  );
}

class _TeamSheet extends StatefulWidget {
  const _TeamSheet({required this.liveParts, this.onSubmit, this.onAskTeam});
  final List<Part> Function() liveParts;
  final Future<void> Function(String text)? onSubmit;

  /// 团队运行中向 lead 追问（独立通道，不排队等主生成循环）。
  final Future<String> Function(String text)? onAskTeam;

  @override
  State<_TeamSheet> createState() => _TeamSheetState();
}

class _TeamSheetState extends State<_TeamSheet> {
  List<SubAgent>? _agents;
  Timer? _tick;
  final _input = TextEditingController();
  final _focus = FocusNode();

  /// 面板内的追问记录（问题 + lead 回答）。
  final _asked = <({String question, String? answer})>[];
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    SubAgentStore.load().then((v) {
      if (mounted) setState(() => _agents = v);
    });
    // 400ms 一次：足够跟上进度，又不会把重建压得太密。
    _tick = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 数据

  /// 团队相关的工具调用（分派 / 追加 / 讨论）。
  List<ToolPart> get _toolParts => [
    for (final p in widget.liveParts())
      if (p is ToolPart &&
          (p.name == 'dispatch_subagents' || p.name == 'add_team_tasks' || p.name == 'discuss_subagents'))
        p,
  ];

  bool get _busy => _toolParts.any((p) => p.output == null);

  /// 最新一张任务板。优先用运行期 `meta.board`（实时），退回已完成的 output。
  Map<String, dynamic>? get _board {
    // 第一优先：内存里那张活的任务板。
    //
    // 之前只读 meta.board（序列化过的 JSON 快照），一旦这步没写进去或写失败，
    // 面板就永远是空的。活的 TeamBoard 不依赖序列化，任务板一改这里就能看见。
    final live = activeTeamBoard;
    if (live != null && live.tasks.isNotEmpty) return live.toJson();
    for (final p in _toolParts.reversed) {
      final meta = p.meta?['board'];
      if (meta is Map) {
        final m = asMap(meta);
        if (m['tasks'] is List) return m;
      }
    }
    for (final p in _toolParts.reversed) {
      final raw = p.output;
      if (raw == null) continue;
      final j = tryJsonDecode(raw);
      if (j is Map && asMap(j)['board'] is Map) {
        final m = asMap(asMap(j)['board']);
        if (m['tasks'] is List) return m;
      }
    }
    return null;
  }

  List<Map<String, dynamic>> get _boardTasks {
    final b = _board;
    if (b == null) return const [];
    final tasks = b['tasks'];
    if (tasks is! List) return const [];
    return [
      for (final e in tasks)
        if (e is Map) asMap(e),
    ];
  }

  /// 每个子智能体当前的状态词与副标题。
  ({String status, String? detail}) _stateOf(String agent) {
    for (final row in _boardTasks) {
      if (asStr(row['agent']) != agent) continue;
      final st = asStr(row['status']);
      if (st == 'running') {
        return (status: t('运行中', 'running'), detail: _taskLine(row));
      }
      if (st == 'pending') {
        return (status: t('等待前置', 'waiting'), detail: _taskLine(row));
      }
    }
    return (status: t('待命', 'idle'), detail: null);
  }

  /// 某次工具调用对应的任务板（meta 优先，退回 output）。
  Map<String, dynamic>? _boardOf(ToolPart p) {
    final meta = p.meta?['board'];
    if (meta is Map) {
      final m = asMap(meta);
      if (m['tasks'] is List) return m;
    }
    final raw = p.output;
    if (raw == null) return null;
    final j = tryJsonDecode(raw);
    if (j is! Map) return null;
    final b = asMap(j)['board'];
    if (b is Map && asMap(b)['tasks'] is List) return asMap(b);
    return null;
  }

  /// 整段对话里所有分派的累计消耗（对齐清水的「本次合计」）。
  ({int tokIn, int tokOut, int ms, int boards}) get _totals {
    var tokIn = 0;
    var tokOut = 0;
    var ms = 0;
    var boards = 0;
    for (final p in _toolParts) {
      final b = _boardOf(p);
      if (b == null) continue;
      boards++;
      if (b['tokens_in'] is num) {
        tokIn += (b['tokens_in'] as num).toInt();
      }
      if (b['tokens_out'] is num) {
        tokOut += (b['tokens_out'] as num).toInt();
      }
      if (b['elapsed_ms'] is num) {
        ms += (b['elapsed_ms'] as num).toInt();
      }
    }
    return (tokIn: tokIn, tokOut: tokOut, ms: ms, boards: boards);
  }

  int get _runningCount => _boardTasks.where((row) => asStr(row['status']) == 'running').length;

  int get _pendingCount => _boardTasks.where((row) => asStr(row['status']) == 'pending').length;

  String _taskLine(Map<String, dynamic> task) {
    final s = asStr(task['task']).replaceAll('\n', ' ').trim();
    return s.length <= 42 ? s : '${s.substring(0, 42)}…';
  }

  /// 讨论工具的历史结果（不是任务板）。
  List<_Turn> get _turns {
    final out = <_Turn>[];
    for (final p in _toolParts) {
      final raw = p.output;
      if (raw == null) continue;
      final j = tryJsonDecode(raw);
      if (j is! Map) continue;
      final turns = asMap(j)['turns'];
      if (turns is! List) continue;
      for (final e in turns) {
        if (e is! Map) continue;
        final m = asMap(e);
        out.add(
          _Turn(
            agent: '${t('第', 'R')}${m['round']} · ${asStr(m['agent'])}',
            ok: m['ok'] == true,
            text: asStr(m['output']),
          ),
        );
      }
    }
    return out;
  }

  /// lead 建板时的发言：把这次任务板的目标与分工列出来。
  String get _leadLine {
    final b = _board;
    if (b == null) return '';
    final title = asStr(b['title']).trim();
    final parts = <String>[];
    for (final row in _boardTasks) {
      final id = asStr(row['id']);
      final agent = asStr(row['agent']);
      final task = asStr(row['task']).replaceAll('\n', ' ').trim();
      final short = task.length <= 60 ? task : '${task.substring(0, 60)}…';
      parts.add('$id $agent「$short」');
    }
    final head = title.isEmpty ? t('已建立共享任务板', 'Shared task board created') : title;
    return parts.isEmpty ? head : '$head：${parts.join('；')}';
  }

  String _statusLabel(String status) => switch (status) {
    'running' => t('运行中', 'running'),
    'pending' => t('等待前置', 'waiting'),
    'done' => t('已完成', 'done'),
    'failed' => t('失败', 'failed'),
    'skipped' => t('已跳过', 'skipped'),
    _ => status,
  };

  Color _statusColor(String status, ColorScheme scheme) => switch (status) {
    'running' => scheme.primary,
    'done' => scheme.tertiary,
    'failed' => scheme.error,
    'pending' || 'skipped' => scheme.outline,
    _ => scheme.outline,
  };

  // ---------------------------------------------------------------- 视图

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final agents = _agents;
    final board = _board;
    final tasks = _boardTasks;
    final turns = _turns;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final inserting = MediaQuery.viewInsetsOf(context).bottom;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      minChildSize: 0.35,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                _header(context, style),
                if (_runningCount > 0 || _pendingCount > 0) ...[const SizedBox(height: 10), _summary(context, style)],
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
                      status: _runningCount > 0 ? t('运行中', 'running') : t('待命', 'idle'),
                      detail: _runningCount > 0 ? t('协调 $_runningCount 个子智能体', 'coordinating $_runningCount') : null,
                      running: _runningCount > 0,
                    ),
                    if (agents != null)
                      for (final a in agents)
                        () {
                          final s = _stateOf(a.name);
                          return _memberCard(
                            context,
                            name: a.name,
                            tags: [if (a.readOnly) t('只读', 'read-only'), if (!a.enabled) t('已停用', 'disabled')],
                            status: s.status,
                            detail: s.detail,
                            running: s.status == t('运行中', 'running'),
                          );
                        }(),
                  ],
                ),
                if (agents == null) const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Text(t('共享任务', 'Shared tasks'), style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(width: 6),
                    Text('${tasks.length}', style: style),
                    if (_busy) ...[
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(strokeWidth: 1.6, color: scheme.primary),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                if (tasks.isEmpty)
                  _emptyCard(context, style)
                else
                  for (final row in tasks) _taskCard(context, row, style),
                if (turns.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text('${t('讨论记录', 'Discussion')} ${turns.length}', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  for (final turn in turns) _turnCard(context, turn, style),
                ],
                if (board != null && turns.isEmpty && tasks.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text(t('团队会话', 'Team log'), style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Card(
                    color: scheme.surfaceContainerHighest,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(t('lead', 'lead'), style: style),
                          const SizedBox(height: 4),
                          Text(_leadLine, style: const TextStyle(height: 1.35)),
                        ],
                      ),
                    ),
                  ),
                  // 追问记录：团队还在跑时，用户问的话和 lead 的回答都留在这里。
                  for (final item in _asked) _askedCard(context, item, style),
                ],
                const SizedBox(height: 10),
                Text(
                  t(
                    '依赖任务会在前置完成后自动开工；前置失败时下游自动跳过。点任务可展开产出。',
                    'Dependent tasks start as soon as their parents finish; if a parent fails the children are skipped. Tap a task to see its output.',
                  ),
                  style: style,
                ),
                SizedBox(height: inserting > 0 ? inserting + 8 : 8),
              ],
            ),
          ),
          _composer(context, style),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, TextStyle? style) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
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
                  '主智能体作为 lead 拆解任务，子智能体并行执行并自动交接结果',
                  'The lead splits the work; sub-agents run in parallel and hand results downstream',
                ),
                style: style,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _summary(BuildContext context, TextStyle? style) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        if (_runningCount > 0) _pill(context, t('$_runningCount 个运行中', '$_runningCount running'), scheme.primary),
        if (_pendingCount > 0) _pill(context, t('$_pendingCount 个等待前置', '$_pendingCount waiting'), scheme.outline),
        () {
          final tot = _totals;
          if (tot.tokIn == 0 && tot.tokOut == 0) return const SizedBox.shrink();
          return Text(
            '${t('本次合计 ', 'total ')}↑${formatTokens(tot.tokIn)} ↓${formatTokens(tot.tokOut)}'
            ' · ${formatTokens(tot.tokIn + tot.tokOut)} tokens'
            '${tot.ms > 0 ? ' · ${_duration(tot.ms)}' : ''}',
            style: style,
          );
        }(),
      ],
    );
  }

  String _duration(int ms) => formatDuration(ms);

  Widget _pill(BuildContext context, String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
    child: Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
  );

  Widget _emptyCard(BuildContext context, TextStyle? style) => Card(
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
  );

  Widget _taskCard(BuildContext context, Map<String, dynamic> task, TextStyle? style) {
    final scheme = Theme.of(context).colorScheme;
    final status = asStr(task['status']);
    final deps = task['depends_on'];
    final depList = deps is List ? deps.map(asStr).where((e) => e.isNotEmpty).toList() : const <String>[];
    final output = asStr(task['output']);
    final error = asStr(task['error']);
    final stepsRaw = task['steps'];
    final stepCount = stepsRaw is List ? stepsRaw.length : 0;
    var lastThought = '';
    if (stepsRaw is List) {
      for (final e in stepsRaw.reversed) {
        if (e is! Map) continue;
        if (asStr(e['type']) != 'reasoning') continue;
        lastThought = asStr(e['output']).replaceAll(RegExp(r'\s+'), ' ').trim();
        if (lastThought.length > 80) lastThought = '${lastThought.substring(0, 80)}…';
        break;
      }
    }
    final running = status == 'running';
    final color = _statusColor(status, scheme);
    final head = asStr(task['task']).replaceAll('\n', ' ').trim();
    final short = head.length <= 64 ? head : '${head.substring(0, 64)}…';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: running ? scheme.primaryContainer.withValues(alpha: 0.45) : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: (output.isEmpty && error.isEmpty) ? null : () => _showOutput(context, task),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: running
                        ? SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 1.8, color: color),
                          )
                        : Icon(
                            switch (status) {
                              'done' => Icons.check_circle_outline,
                              'failed' => Icons.error_outline,
                              'skipped' => Icons.remove_circle_outline,
                              _ => Icons.radio_button_unchecked,
                            },
                            size: 14,
                            color: color,
                          ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(short, style: const TextStyle(height: 1.3))),
                  const SizedBox(width: 8),
                  _pill(context, _statusLabel(status), color),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                [
                  asStr(task['id']),
                  asStr(task['agent']),
                  if (task['ms'] is num && (task['ms'] as num) > 0) formatDuration((task['ms'] as num).toInt()),
                ].join(' · '),
                style: style,
              ),
              if (depList.isNotEmpty) Text('${t('依赖', 'depends on')}：${depList.join('、')}', style: style),
              // 最近一条思考：面板里也能看到它在想什么。
              if (lastThought.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${t('思考', 'thinking')}：$lastThought',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: style?.copyWith(fontStyle: FontStyle.italic, height: 1.35),
                  ),
                ),
              if (running && output.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    output.replaceAll(RegExp(r'\s+'), ' '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: style?.copyWith(color: scheme.onSurface, height: 1.35),
                  ),
                ),
              if (stepCount > 0 && running) Text('${t('已跑', 'steps run')} $stepCount', style: style),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(error, style: style?.copyWith(color: scheme.error)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _turnCard(BuildContext context, _Turn turn, TextStyle? style) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(turn.agent, style: style)),
                _pill(
                  context,
                  turn.ok ? t('已完成', 'done') : t('失败', 'failed'),
                  turn.ok ? scheme.tertiary : scheme.error,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              turn.text.isEmpty ? t('（无产出）', '(no output)') : turn.text,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(height: 1.35),
            ),
          ],
        ),
      ),
    );
  }

  Widget _askedCard(BuildContext context, ({String question, String? answer}) item, TextStyle? style) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t('你', 'you'), style: style),
              const SizedBox(height: 4),
              Text(item.question, style: const TextStyle(height: 1.35)),
              const SizedBox(height: 10),
              Text(t('lead', 'lead'), style: style),
              const SizedBox(height: 4),
              if (item.answer == null)
                Row(
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.8, color: scheme.primary),
                    ),
                    const SizedBox(width: 8),
                    Text(t('正在回答…', 'answering…'), style: style),
                  ],
                )
              else
                Text(item.answer!, style: const TextStyle(height: 1.35)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _memberCard(
    BuildContext context, {
    required String name,
    required List<String> tags,
    required String status,
    String? detail,
    bool running = false,
    List<({String agent, String tool, bool ok, int ms})> calls = const [],
  }) {
    final scheme = Theme.of(context).colorScheme;
    final busy = running;
    return SizedBox(
      width: 160,
      child: Card(
        color: busy ? scheme.primaryContainer.withValues(alpha: 0.55) : null,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.circle, size: 8, color: busy ? scheme.primary : scheme.outlineVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(height: 1.2),
                    ),
                  ),
                ],
              ),
              if (tags.isNotEmpty) ...[
                const SizedBox(height: 4),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
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
              ],
              const SizedBox(height: 6),
              Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: busy ? scheme.primary : scheme.onSurfaceVariant,
                  fontWeight: busy ? FontWeight.w600 : null,
                ),
              ),
              if (detail != null)
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                )
              else if (calls.isNotEmpty)
                Text(
                  '${calls.length} ${t('次工具', 'tool calls')}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _composer(BuildContext context, TextStyle? style) {
    final canSend = widget.onSubmit != null;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                focusNode: _focus,
                // 追问进行中先禁掉输入，避免连发把通道压满。
                enabled: canSend && !_asking,
                textInputAction: TextInputAction.send,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: t('问问进度，或要求追加任务…', 'Ask for progress, or add more tasks…'),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(icon: const Icon(Icons.arrow_upward_rounded), onPressed: canSend ? _send : null),
          ],
        ),
      ),
    );
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final ask = widget.onAskTeam;
    final submit = widget.onSubmit;

    // 团队还在跑：走追问通道，把回答留在面板里，不要把用户踢出界面。
    if (_busy && ask != null) {
      _input.clear();
      setState(() {
        _asking = true;
        _asked.add((question: text, answer: null));
      });
      final reply = await ask(text);
      if (!mounted) return;
      setState(() {
        _asking = false;
        if (_asked.isNotEmpty) {
          _asked[_asked.length - 1] = (question: text, answer: reply);
        }
      });
      return;
    }

    if (submit == null) return;
    _input.clear();
    Navigator.of(context).pop();
    await submit(text);
  }

  void _showOutput(BuildContext context, Map<String, dynamic> task) {
    final out = asStr(task['output']);
    final error = asStr(task['error']);
    final steps = task['steps'];
    final stepCount = steps is List ? steps.length : 0;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.92,
        builder: (context, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Text('${asStr(task['id'])} · ${asStr(task['agent'])}', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              [
                _statusLabel(asStr(task['status'])),
                if (stepCount > 0) '$stepCount ${t('步', 'steps')}',
                if (task['ms'] is num && (task['ms'] as num) > 0) formatDuration((task['ms'] as num).toInt()),
              ].join(' · '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Text(asStr(task['task'])),
            const SizedBox(height: 16),
            if (error.isNotEmpty) Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            if (out.isNotEmpty) SelectableText(out),
            if (out.isEmpty && error.isEmpty) const Text('（还没有产出）'),
          ],
        ),
      ),
    );
  }
}

class _Turn {
  const _Turn({required this.agent, required this.ok, required this.text});
  final String agent;
  final bool ok;
  final String text;
}

/// 从任务板 JSON 里取出全部任务行（给单测用）。
List<({String id, String agent, String status, List<String> dependsOn})> parseBoardRows(String json) {
  final j = tryJsonDecode(json);
  if (j is! Map) return const [];
  final board = asMap(j)['board'];
  final tasks = board is Map ? asMap(board)['tasks'] : asMap(j)['tasks'];
  if (tasks is! List) return const [];
  final out = <({String id, String agent, String status, List<String> dependsOn})>[];
  for (final e in tasks) {
    if (e is! Map) continue;
    final m = asMap(e);
    final deps = m['depends_on'];
    out.add((
      id: asStr(m['id']),
      agent: asStr(m['agent']),
      status: asStr(m['status']),
      dependsOn: deps is List ? [for (final d in deps) asStr(d)] : const <String>[],
    ));
  }
  return out;
}
