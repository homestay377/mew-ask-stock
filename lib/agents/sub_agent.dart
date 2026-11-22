import '../core/util.dart';

/// 一个子智能体的配置。
///
/// 主智能体通过 `dispatch_subagents` 把任务分派给它们：每个子智能体有自己的
/// 系统提示词、可选的模型、以及工具白名单（为空表示沿用主智能体的全部工具）。
class SubAgent {
  SubAgent({
    String? id,
    this.name = '',
    this.description = '',
    this.systemPrompt = '',
    this.enabled = true,
    this.modelId,
    this.toolNames = const [],
    this.readOnly = false,
    this.builtin = false,
  }) : id = id ?? newId();

  final String id;
  final String name;

  /// 给主智能体看的一句话说明：这个子智能体擅长什么。
  final String description;

  final String systemPrompt;
  final bool enabled;

  /// 指定模型；null 表示跟随主智能体当轮的模型。
  final String? modelId;

  /// 工具白名单；空表示可用主智能体当轮全部工具。
  final List<String> toolNames;

  /// 只读：在白名单基础上再剔除 [readOnlyBlockedTools] 里的写操作。
  final bool readOnly;

  /// 内置条目，用户可以删掉但不会自动重建（由种子标记文件控制）。
  final bool builtin;

  bool get usable => enabled && name.trim().isNotEmpty;

  SubAgent copyWith({
    String? name,
    String? description,
    String? systemPrompt,
    bool? enabled,
    String? modelId,
    bool clearModelId = false,
    List<String>? toolNames,
    bool? readOnly,
  }) => SubAgent(
    id: id,
    name: name ?? this.name,
    description: description ?? this.description,
    systemPrompt: systemPrompt ?? this.systemPrompt,
    enabled: enabled ?? this.enabled,
    modelId: clearModelId ? null : (modelId ?? this.modelId),
    toolNames: toolNames ?? this.toolNames,
    readOnly: readOnly ?? this.readOnly,
    builtin: builtin,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'systemPrompt': systemPrompt,
    'enabled': enabled,
    'modelId': ?modelId,
    'toolNames': toolNames,
    'readOnly': readOnly,
    'builtin': builtin,
  };

  factory SubAgent.fromJson(Map<String, dynamic> j) => SubAgent(
    id: asStrOrNull(j['id']) ?? newId(),
    name: asStr(j['name']),
    description: asStr(j['description']),
    systemPrompt: asStr(j['systemPrompt']),
    enabled: j['enabled'] is bool ? j['enabled'] as bool : true,
    modelId: asStrOrNull(j['modelId']),
    toolNames: asList(j['toolNames']).map(asStr).where((e) => e.isNotEmpty).toList(),
    readOnly: j['readOnly'] == true,
    builtin: j['builtin'] == true,
  );
}

/// 只读子智能体禁止使用的工具：会改变界面、画线或外部状态的那些。
const readOnlyBlockedTools = <String>{
  'chart_annotate',
  'stock_panel_show',
  // 工作区写操作：只读子智能体只能读文件与列目录
  'workspace_write_file',
  'workspace_edit_file',
};

/// 内置子智能体。提示词按「问股」的实际能力写，不列我们没实现的工具。
final builtinSubAgents = <SubAgent>[
  SubAgent(
    id: '0e0a4f7c-1f0b-4c2a-9a5e-000000000001',
    name: '行情侦察',
    description: '查报价、多级别结构、自选扫描，先摸清现状再汇报',
    systemPrompt:
        '你是行情侦察员，负责快速摸清一只股票或一组股票的现状：'
        '最新报价、多周期（日/周/60 分/30 分）结构方向、有无背驰与买卖点、量能是否配合。'
        '先用工具取数，再下结论；每条结论都要带具体数字，不要只给「偏强」「偏弱」这种空话。',
    toolNames: [
      'stock_quote',
      'stock_kline',
      'stock_levels',
      'scan_stocks',
      'chart_context',
      'http_request',
      'workspace_read_file',
      'workspace_write_file',
    ],
    readOnly: false,
    builtin: true,
  ),
  SubAgent(
    id: '0e0a4f7c-1f0b-4c2a-9a5e-000000000002',
    name: '结构审查',
    description: '只审查不修改：复核缠论笔/中枢/背驰/买卖点是否成立，挑出矛盾',
    systemPrompt:
        '你是结构审查员，只做复核，不改图、不改面板、不下单。'
        '重点看：中枢区间与最新价的关系、背驰力度是否够强、买卖点引用的中枢是否过期、'
        '日/周/60 分/30 分的方向是否互相矛盾、量能是否配合价格（放量突破还是缩量反抽）、'
        'K 线根数是否足够（少于 400 根要明说结论不可靠）。'
        '发现问题要指出具体是哪一段、哪个价位、为什么，并给出可执行的修正方向。',
    toolNames: ['analyze_chan', 'stock_kline', 'stock_levels', 'chart_context'],
    readOnly: true,
    builtin: true,
  ),
  SubAgent(
    id: '0e0a4f7c-1f0b-4c2a-9a5e-000000000003',
    name: '资料研究',
    description: '查基本面与公开资料，结论必须带出处，不编数据',
    systemPrompt:
        '你是资料研究员，负责查基本面与公开信息：市盈率、市值、每股收益、行业地位、近期公开消息。'
        '只用工具真实取到的数据，取不到就明确写「取不到」，绝不凭印象编数字。'
        '每条结论后面注明来源（哪个接口/哪一天）。',
    toolNames: [
      'get_fundamental',
      'stock_quote',
      'chart_context',
      'http_request',
      'workspace_read_file',
      'workspace_write_file',
      'workspace_edit_file',
    ],
    readOnly: false,
    builtin: true,
  ),
  SubAgent(
    id: '0e0a4f7c-1f0b-4c2a-9a5e-000000000004',
    name: '策略方案',
    description: '只出方案不动手：给支撑压力、加减仓条件与失效位',
    systemPrompt:
        '你是策略规划员，只出方案、不改任何东西。'
        '基于给定的结构与价位，给出：关键支撑与压力（写明怎么算出来的）、'
        '什么条件下才考虑加仓、什么条件下减仓、方案在哪个价位失效。'
        '必须写风险：如果判断错了，最先坏掉的是哪个条件。不要给收益承诺。',
    toolNames: ['stock_levels', 'analyze_chan', 'stock_kline', 'chart_context'],
    readOnly: true,
    builtin: true,
  ),
  SubAgent(
    id: '0e0a4f7c-1f0b-4c2a-9a5e-000000000006',
    name: '数据核验',
    description: '查数据新鲜度与结论矛盾：哪些价已经过期、哪些说法互相打架',
    systemPrompt:
        '你是数据核验员，只核对、不下判断。逐条检查：'
        '① 数据是哪天拉的、是否跨了交易日（看 chart_context 与 stock_levels 里的 data 块：fetched_at、closed、from_cache、quality）；'
        '② 引用的价位和中枢是不是上一根 K 线之前的值，有没有拿旧数据当现状；'
        '③ 不同周期、不同工具给出的方向或价位是否互相矛盾；'
        '④ 有没有把「取不到」写成数字。发现问题就写清是哪一条、错在哪、应该以哪份数据为准。',
    toolNames: ['chart_context', 'stock_levels', 'stock_kline', 'analyze_chan'],
    readOnly: true,
    builtin: true,
  ),
  SubAgent(
    id: '0e0a4f7c-1f0b-4c2a-9a5e-000000000005',
    name: '图文标注',
    description: '把结论画到图上：支撑压力线、区间、标注文字',
    systemPrompt:
        '你是图表标注员，负责把已经确定的结论画到 K 线图上：支撑/压力线、区间框、关键文字标注。'
        '只画任务里明确给出的价位，不要自己发明新价位；画完要说明画了几个对象、分别在哪。'
        '画线会随交易日切换自动作废，所以不要向用户承诺「这条线会一直留着」。',
    toolNames: ['chart_annotate', 'stock_panel_show', 'stock_kline', 'chart_context'],
    builtin: true,
  ),
];

/// 给模型看的子智能体目录。
String subAgentCatalog(List<SubAgent> agents) {
  final lines = <String>[];
  for (final a in agents) {
    final note = a.readOnly ? '（只读，不会改动图表）' : '（可以改动图表）';
    final desc = a.description.trim().isEmpty ? '（没写说明）' : a.description.trim();
    lines.add('- ${a.name}$note：$desc');
  }
  return lines.join('\n');
}
