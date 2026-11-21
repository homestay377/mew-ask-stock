import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../agents/sub_agent.dart';
import '../../agents/sub_agent_store.dart';
import '../../core/i18n.dart';
import '../../state/settings_store.dart';
import '../widgets/common.dart';

/// 可选工具。白名单里出现别的名字也不会报错（子智能体只是用不上）。
const _toolCandidates = <String>[
  'stock_kline',
  'analyze_chan',
  'stock_quote',
  'stock_levels',
  'scan_stocks',
  'get_fundamental',
  'chart_context',
  'chart_annotate',
  'stock_panel_show',
  'search_web',
  'scrape_web',
];

/// 子智能体管理页。
///
/// 这些配置不是 AppSettings 的一部分：它们只服务于 `dispatch_subagents`，
/// 由 SubAgentStore 单独存成 sub_agents.json，改动立刻落盘。
class SubAgentsPage extends StatefulWidget {
  const SubAgentsPage({super.key});

  @override
  State<SubAgentsPage> createState() => _SubAgentsPageState();
}

class _SubAgentsPageState extends State<SubAgentsPage> {
  List<SubAgent>? _agents;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await SubAgentStore.load();
    if (!mounted) return;
    setState(() => _agents = list);
  }

  Future<void> _save() async {
    final list = _agents;
    if (list == null) return;
    await SubAgentStore.save(list);
  }

  Future<void> _edit(SubAgent agent) async {
    final models = [
      for (final e in context.read<SettingsStore>().value.allModels())
        (id: e.model.id, label: e.model.displayName.isEmpty ? e.model.modelId : e.model.displayName),
    ];
    final updated = await showDialog<SubAgent>(
      context: context,
      builder: (_) => _SubAgentDialog(agent: agent, models: models, isNew: false),
    );
    if (updated == null || !mounted) return;
    setState(() {
      final list = _agents!;
      final i = list.indexWhere((e) => e.id == updated.id);
      if (i >= 0) list[i] = updated;
    });
    await _save();
  }

  Future<void> _add() async {
    final models = [
      for (final e in context.read<SettingsStore>().value.allModels())
        (id: e.model.id, label: e.model.displayName.isEmpty ? e.model.modelId : e.model.displayName),
    ];
    final created = await showDialog<SubAgent>(
      context: context,
      builder: (_) => _SubAgentDialog(
        agent: SubAgent(name: t('新子智能体', 'New sub-agent')),
        models: models,
        isNew: true,
      ),
    );
    if (created == null || !mounted) return;
    setState(() => _agents!.add(created));
    await _save();
  }

  Future<void> _toggle(SubAgent agent, bool on) async {
    setState(() {
      final i = _agents!.indexWhere((e) => e.id == agent.id);
      if (i >= 0) _agents![i] = agent.copyWith(enabled: on);
    });
    await _save();
  }

  Future<void> _delete(SubAgent agent) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('删除「${agent.name}」？', 'Delete "${agent.name}"?')),
        content: Text(t('只会删掉这份配置，对话记录不受影响。', 'Only this configuration is removed; chats are untouched.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('取消', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('删除', 'Delete'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _agents!.removeWhere((e) => e.id == agent.id));
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final agents = _agents;
    return Scaffold(
      appBar: AppBar(
        title: Text(t('子智能体', 'Sub-agents')),
        actions: [
          IconButton(
            onPressed: agents == null ? null : _add,
            icon: const Icon(Icons.add_rounded),
            tooltip: t('新增', 'Add'),
          ),
        ],
      ),
      body: agents == null
          ? const Center(child: CircularProgressIndicator())
          : agents.isEmpty
          ? EmptyState(
              icon: Icons.smart_toy_outlined,
              title: t('还没有子智能体', 'No sub-agents yet'),
              subtitle: t('主智能体可以把独立的检索、复核、出方案分派给它们', 'The main agent can delegate research and reviews to them'),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: Text(
                      t(
                        '主智能体通过 dispatch_subagents 分派任务；同一次分派里的多条会并行执行。只读的子智能体不会改图或改面板。',
                        'The main agent delegates through dispatch_subagents; tasks in one batch run in parallel. Read-only agents never modify the chart.',
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
                for (final a in agents)
                  Card(
                    child: ListTile(
                      leading: IconBadge(
                        a.readOnly ? Icons.visibility_outlined : Icons.smart_toy_outlined,
                        color: a.enabled ? null : Theme.of(context).colorScheme.outline,
                      ),
                      title: Row(
                        children: [
                          Flexible(child: Text(a.name, overflow: TextOverflow.ellipsis)),
                          if (a.readOnly) ...[
                            const SizedBox(width: 6),
                            Text(
                              t('只读', 'read-only'),
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: Theme.of(context).colorScheme.primary),
                            ),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        a.description.isEmpty ? t('没有说明', 'No description') : a.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Switch(value: a.enabled, onChanged: (v) => _toggle(a, v)),
                          IconButton(
                            icon: const Icon(Icons.delete_outline_rounded, size: 20),
                            tooltip: t('删除', 'Delete'),
                            onPressed: () => _delete(a),
                          ),
                        ],
                      ),
                      onTap: () => _edit(a),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _SubAgentDialog extends StatefulWidget {
  const _SubAgentDialog({required this.agent, required this.models, required this.isNew});

  final SubAgent agent;
  final List<({String id, String label})> models;
  final bool isNew;

  @override
  State<_SubAgentDialog> createState() => _SubAgentDialogState();
}

class _SubAgentDialogState extends State<_SubAgentDialog> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  late final TextEditingController _prompt;
  late String? _modelId;
  late Set<String> _tools;
  late bool _readOnly;

  @override
  void initState() {
    super.initState();
    final a = widget.agent;
    _name = TextEditingController(text: a.name);
    _desc = TextEditingController(text: a.description);
    _prompt = TextEditingController(text: a.systemPrompt);
    _modelId = a.modelId;
    _tools = a.toolNames.toSet();
    _readOnly = a.readOnly;
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      toast(context, t('名字不能为空', 'Name cannot be empty'), error: true);
      return;
    }
    final agent = SubAgent(
      id: widget.agent.id,
      name: name,
      description: _desc.text.trim(),
      systemPrompt: _prompt.text.trim(),
      enabled: widget.agent.enabled,
      modelId: _modelId,
      toolNames: _tools.toList(),
      readOnly: _readOnly,
      builtin: widget.agent.builtin,
    );
    Navigator.pop(context, agent);
  }

  @override
  Widget build(BuildContext context) {
    final modelOptions = <({String? id, String label})>[
      (id: null, label: t('跟随主智能体当前的模型', 'Follow the main agent model')),
      for (final m in widget.models) (id: m.id, label: m.label),
    ];
    return AlertDialog(
      title: Text(widget.isNew ? t('新建子智能体', 'New sub-agent') : t('编辑子智能体', 'Edit sub-agent')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                decoration: InputDecoration(labelText: t('名称', 'Name'), hintText: t('例如：行情侦察', 'e.g. Quote scout')),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _desc,
                decoration: InputDecoration(
                  labelText: t('一句话说明', 'One-line description'),
                  hintText: t('给主智能体看：它擅长什么', 'What it is good at, shown to the main agent'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _prompt,
                maxLines: 6,
                minLines: 3,
                decoration: InputDecoration(
                  labelText: t('系统提示词', 'System prompt'),
                  alignLabelWithHint: true,
                  hintText: t('只写职责与纪律；工具使用由运行时统一交代', 'Duties and rules only; tool usage is explained by the runtime'),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: _modelId,
                decoration: InputDecoration(labelText: t('模型', 'Model')),
                items: [
                  for (final m in modelOptions)
                    DropdownMenuItem(
                      value: m.id,
                      child: Text(m.label, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => _modelId = v),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t('只读', 'Read-only')),
                subtitle: Text(t('剔除改图、改面板这类写操作', 'Strips write-capable tools such as chart edits')),
                value: _readOnly,
                onChanged: (v) => setState(() => _readOnly = v),
              ),
              const SizedBox(height: 4),
              Text(
                t('工具白名单（不选＝可用全部工具）', 'Tool whitelist (empty = all tools)'),
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final name in _toolCandidates)
                    FilterChip(
                      label: Text(name),
                      selected: _tools.contains(name),
                      onSelected: (on) => setState(() => on ? _tools.add(name) : _tools.remove(name)),
                    ),
                ],
              ),
              if (_readOnly && _tools.any(readOnlyBlockedTools.contains))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    t(
                      '白名单里有写操作工具，它们会被自动剔除。',
                      'The whitelist has write tools; they will be filtered out automatically.',
                    ),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t('取消', 'Cancel'))),
        FilledButton(onPressed: _submit, child: Text(t('保存', 'Save'))),
      ],
    );
  }
}
