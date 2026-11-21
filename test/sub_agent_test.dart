import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/agents/sub_agent.dart';
import 'package:mewhub/agents/sub_agent_tools.dart';

void main() {
  test('子智能体 JSON 往返不丢字段', () {
    final a = SubAgent(
      name: '测试员',
      description: '说明',
      systemPrompt: '提示词',
      modelId: 'gpt-x',
      toolNames: ['stock_kline', 'chart_context'],
      readOnly: true,
      builtin: false,
    );
    final b = SubAgent.fromJson(a.toJson());
    expect(b.id, a.id);
    expect(b.name, '测试员');
    expect(b.description, '说明');
    expect(b.systemPrompt, '提示词');
    expect(b.modelId, 'gpt-x');
    expect(b.toolNames, ['stock_kline', 'chart_context']);
    expect(b.readOnly, isTrue);
    expect(b.enabled, isTrue);
    expect(b.builtin, isFalse);
  });

  test('缺字段的旧配置能读出来，不崩', () {
    final b = SubAgent.fromJson({'name': '只有名字'});
    expect(b.name, '只有名字');
    expect(b.enabled, isTrue);
    expect(b.toolNames, isEmpty);
    expect(b.modelId, isNull);
    expect(b.id, isNotEmpty);
  });

  test('copyWith 能清掉模型与改只读', () {
    final a = SubAgent(name: 'a', modelId: 'm');
    expect(a.copyWith(clearModelId: true).modelId, isNull);
    expect(a.copyWith(readOnly: true).readOnly, isTrue);
    expect(a.copyWith(name: 'b').id, a.id);
  });

  test('只读黑名单覆盖会改动图表的工具', () {
    expect(readOnlyBlockedTools, contains('chart_annotate'));
    expect(readOnlyBlockedTools, contains('stock_panel_show'));
    // 只读工具不该在黑名单里，否则子智能体什么都干不了。
    expect(readOnlyBlockedTools, isNot(contains('stock_kline')));
    expect(readOnlyBlockedTools, isNot(contains('analyze_chan')));
  });

  test('内置子智能体都有名字和提示词，且只读的没把写工具写进白名单', () {
    expect(builtinSubAgents, isNotEmpty);
    for (final a in builtinSubAgents) {
      expect(a.name.trim(), isNotEmpty, reason: '名字不能空');
      expect(a.systemPrompt.trim(), isNotEmpty, reason: '${a.name} 缺提示词');
      expect(a.usable, isTrue, reason: '${a.name} 应该默认启用');
      if (a.readOnly) {
        for (final t in a.toolNames) {
          expect(readOnlyBlockedTools, isNot(contains(t)), reason: '${a.name} 是只读的，却申请了 $t');
        }
      }
    }
  });

  test('内置 id 不重复', () {
    final ids = builtinSubAgents.map((e) => e.id).toList();
    expect(ids.toSet().length, ids.length);
  });

  test('目录里带名字、说明和只读标记', () {
    final catalog = subAgentCatalog(builtinSubAgents);
    for (final a in builtinSubAgents) {
      expect(catalog, contains(a.name));
    }
    expect(catalog, contains('只读'));
  });

  test('empty 名字或未启用就不算可用', () {
    expect(SubAgent(name: '  ').usable, isFalse);
    expect(SubAgent(name: 'x', enabled: false).usable, isFalse);
    expect(SubAgent(name: 'x').usable, isTrue);
  });

  test('分派与讨论两个工具都注册，必填项对得上', () {
    final tools = buildSubAgentTools(
      agents: [
        SubAgent(name: '甲'),
        SubAgent(name: '乙', enabled: false),
      ],
    );
    expect([for (final t in tools) t.name], ['dispatch_subagents', 'discuss_subagents']);
    expect(tools.first.parameters['required'], containsAll(['tool_title', 'assignments']));
    expect(tools.last.parameters['required'], contains('topic'));
  });

  test('没有可用子智能体时一个工具都不注册', () {
    expect(buildSubAgentTools(agents: [SubAgent(name: ' ')]), isEmpty);
    expect(buildSubAgentTools(agents: [SubAgent(name: 'x', enabled: false)]), isEmpty);
  });

  test('不在对话生成过程中调用，返回明确错误而不是崩', () async {
    final tools = buildSubAgentTools(agents: [SubAgent(name: '甲')]);
    final out = await tools.first.execute({
      'tool_title': '看一下',
      'assignments': [
        {'agent': '甲', 'task': '查 300274 日线'},
      ],
    });
    expect(out, contains('只能在一次对话生成过程中使用'));
  });
}
