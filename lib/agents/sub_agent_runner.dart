import 'dart:convert';

import '../ai/factory.dart';
import '../ai/message.dart';
import '../ai/provider.dart';
import '../ai/provider_config.dart';
import '../chat/accumulator.dart';
import '../core/net.dart';
import '../core/util.dart';
import '../tools/http_tool.dart';
import '../tools/tool.dart';
import '../tools/workspace_tools.dart';
import 'sub_agent.dart';
import 'tool_run_context.dart';

/// 子智能体之间互相提问。
const askPeerToolName = 'ask_peer';

/// 子智能体向主智能体求助。
const askMainToolName = 'ask_main_agent';

/// 子智能体申请额外工具。
const requestCapabilityToolName = 'request_capability';

/// 子智能体在某一轮里调用某个工具的记录。
class SubAgentStep {
  const SubAgentStep({required this.tool, required this.output, this.isError = false, this.ms = 0});

  final String tool;
  final String output;
  final bool isError;
  final int ms;

  Map<String, dynamic> toJson() => {'tool': tool, 'ok': !isError, 'ms': ms, 'chars': output.length};
}

/// 一个子智能体跑完一个任务的结果。
class SubAgentResult {
  SubAgentResult({
    required this.agent,
    required this.task,
    required this.output,
    this.error,
    this.steps = const [],
    this.usage = const TokenUsage(),
    this.elapsedMs = 0,
    this.cancelled = false,
  });

  final String agent;
  final String task;
  final String output;
  final String? error;
  final List<SubAgentStep> steps;
  final TokenUsage usage;
  final int elapsedMs;
  final bool cancelled;

  bool get ok => error == null && !cancelled;

  SubAgentResult copyWith({String? output, String? error}) => SubAgentResult(
    agent: agent,
    task: task,
    output: output ?? this.output,
    error: error ?? this.error,
    steps: steps,
    usage: usage,
    elapsedMs: elapsedMs,
    cancelled: cancelled,
  );

  Map<String, dynamic> toJson() => {
    'agent': agent,
    'ok': ok,
    'output': output,
    if (error != null) 'error': error,
    if (cancelled) 'cancelled': true,
    'steps': [for (final s in steps) s.toJson()],
    'tokens': {'input': usage.input, 'output': usage.output},
    'ms': elapsedMs,
  };
}

String _clip(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…（截断，原 ${s.length} 字）';

/// 模型跑满步数仍未给结论时的兜底稿。
///
/// 关键区别：不是把工具原文整段倒给主智能体（那样等于让主控再去啃一遍 JSON），
/// 而是按交付格式声明「取了什么、有几条失败、但没形成结论」。
String _fallbackDigest(List<SubAgentStep> steps) {
  if (steps.isEmpty) return '';
  final okCount = steps.where((s) => !s.isError).length;
  final failed = <String>{};
  final tools = <String>[];
  for (final s in steps) {
    if (!tools.contains(s.tool)) tools.add(s.tool);
    if (s.isError) failed.add(s.tool);
  }
  final b = StringBuffer()
    ..writeln('【结论】未能形成判断：本次任务跑满 ${steps.length} 步工具调用，但模型没有给出结论。')
    ..writeln('【证据】共调用 ${steps.length} 次工具（成功 $okCount 次），涉及：${tools.join('、')}。');
  for (final s in steps.where((s) => !s.isError).take(4)) {
    b.writeln('- ${s.tool}：${_clip(s.output.replaceAll(String.fromCharCode(10), ' '), 200)}');
  }
  if (failed.isNotEmpty) {
    b.writeln('【未完成】以下工具调用失败：${failed.join('、')}。');
  } else {
    b.writeln('【未完成】缺一个明确结论，建议主智能体据此重派或自行判断。');
  }
  return b.toString().trimRight();
}

/// 让一个子智能体独立完成任务：自己的系统提示词、可选模型、工具白名单，
/// 最多 [maxSteps] 轮「模型出结论 → 执行工具 → 再问」。
///
/// 和参考实现（ds7891/- 的 Kotlin 版）的关系：结构与预算一致，代码是按
/// MewHub 的 Dart 接口重写的，不是移植。
class SubAgentRunner {
  SubAgentRunner(this.ctx, {this.peers = const [], this.cancelOverride});

  final ToolRunContext ctx;

  /// 单个任务的取消令牌。为空时用 [ctx] 的全局令牌。
  ///
  /// 团队任务板给每个任务一个独立令牌，界面上就能只停掉某一个子智能体，
  /// 而不打断同批其他任务（对齐清水 1.4.2 的单独终止）。
  final CancelToken? cancelOverride;

  CancelToken get _cancel => cancelOverride ?? ctx.cancel;

  /// 同批的其他子智能体，供 `ask_peer` 互相提问。
  final List<SubAgent> peers;

  /// 运行期通过 `request_capability` 获批的工具名。
  ///
  /// 和清水 1.4.2 的做法一致：获批后直接追加进本轮后续步骤，不用重开任务。
  final Set<String> _grantedTools = <String>{};

  /// 单个任务最多几轮工具来回。
  static const maxSteps = 24;

  /// 主控 0 → 子智能体 1 → 它问的同伴 2。再深就停，避免互相问个没完。
  static const maxDepth = 2;

  /// 一个子智能体最多问几次同伴。
  static const maxPeerQuestions = 3;

  /// 一个子智能体最多问几次主智能体。
  static const maxMainQuestions = 3;

  /// 一个子智能体最多申请几次额外工具。
  static const maxCapabilityRequests = 3;

  static const _toolTimeout = Duration(minutes: 3);
  static const _stepOutputLimit = 4000;

  Future<SubAgentResult> run(SubAgent agent, String task, {String extraContext = ''}) async {
    final started = DateTime.now();
    int elapsed() => DateTime.now().difference(started).inMilliseconds;
    final text = task.trim();
    if (text.isEmpty) {
      return SubAgentResult(agent: agent.name, task: task, output: '', error: '任务描述为空', elapsedMs: 0);
    }
    if (ctx.depth > maxDepth) {
      return SubAgentResult(
        agent: agent.name,
        task: text,
        output: '',
        error: '子智能体不能再分派子智能体（已到达嵌套上限）',
        elapsedMs: elapsed(),
      );
    }
    final (:provider, :model) = _modelFor(agent);
    if (provider.keys.isEmpty &&
        !provider.trimmedBaseUrl.contains('127.0.0.1') &&
        !provider.trimmedBaseUrl.contains('localhost')) {
      return SubAgentResult(
        agent: agent.name,
        task: text,
        output: '',
        error: '「${provider.name}」还没有填写 API Key，子智能体无法工作',
        elapsedMs: elapsed(),
      );
    }

    var peerBudget = maxPeerQuestions;
    var mainBudget = maxMainQuestions;
    var capBudget = maxCapabilityRequests;
    final tools = _toolsFor(
      agent,
      allowPeers: ctx.depth < maxDepth,
      onPeerBudget: () => peerBudget > 0 ? (peerBudget -= 1) >= 0 : false,
      onMainBudget: () => mainBudget > 0 ? (mainBudget -= 1) >= 0 : false,
      onCapBudget: () => capBudget > 0 ? (capBudget -= 1) >= 0 : false,
      granted: _grantedTools,
    );
    var usable = model.tools ? tools : const <AppTool>[];
    final ai = providerFor(provider);
    final msgs = <ChatMessage>[
      ChatMessage.text(Role.system, _systemPrompt(agent, usable)),
      ChatMessage.text(
        Role.user,
        extraContext.trim().isEmpty ? text : '${text.trim()}\n\n---\n同一批里其他任务已经完成的结果，供你参考：\n${extraContext.trim()}',
      ),
    ];
    var params = GenerationParams(
      model: model,
      tools: [for (final t in usable) t.spec],
      stream: true,
      sessionId: 'sub-${agent.id}-${DateTime.now().microsecondsSinceEpoch}',
    );

    var usage = const TokenUsage();
    final steps = <SubAgentStep>[];
    var lastText = '';
    var failure = '';
    var byName = {for (final t in usable) t.name: t};
    ctx.onProgress?.call('${agent.name} · 开工');

    for (var step = 0; step < maxSteps; step++) {
      if (_cancel.isCancelled) break;
      // request_capability 获批的工具要能从下一步起就用上，所以每轮重算工具表。
      if (step > 0 && _grantedTools.isNotEmpty) {
        usable = model.tools
            ? _toolsFor(
                agent,
                allowPeers: ctx.depth < maxDepth,
                onPeerBudget: () => peerBudget > 0 ? (peerBudget -= 1) >= 0 : false,
                onMainBudget: () => mainBudget > 0 ? (mainBudget -= 1) >= 0 : false,
                onCapBudget: () => capBudget > 0 ? (capBudget -= 1) >= 0 : false,
                granted: _grantedTools,
              )
            : const <AppTool>[];
        params = GenerationParams(
          model: model,
          tools: [for (final t in usable) t.spec],
          stream: true,
          sessionId: params.sessionId,
        );
        byName = {for (final t in usable) t.name: t};
      }
      final round = PartAccumulator();
      try {
        await for (final chunk in ai.stream(msgs, params, cancel: _cancel)) {
          round.add(chunk);
        }
      } catch (e) {
        failure = '$e';
        break;
      }
      usage = usage + round.usage;
      lastText = _textOf(round.parts);
      final pending = round.pendingTools;
      if (pending.isEmpty) {
        msgs.add(ChatMessage(role: Role.assistant, parts: round.parts));
        break;
      }
      for (final call in pending) {
        if (_cancel.isCancelled) break;
        final sw = Stopwatch()..start();
        var isError = false;
        String out;
        final tool = byName[call.name];
        if (tool == null) {
          out = jsonEncode({'error': '这个子智能体没有工具 ${call.name}'});
          isError = true;
        } else {
          try {
            out = await tool.execute(call.inputJson).timeout(_toolTimeout);
          } catch (e) {
            out = jsonEncode({'error': '$e'});
            isError = true;
          }
        }
        sw.stop();
        final idx = round.parts.indexWhere((p) => identical(p, call));
        if (idx >= 0) round.parts[idx] = call.copyWith(output: out, isError: isError);
        steps.add(
          SubAgentStep(
            tool: call.name,
            output: _clip(out, _stepOutputLimit),
            isError: isError,
            ms: sw.elapsedMilliseconds,
          ),
        );
        ctx.onProgress?.call('${agent.name} · ${call.name}${_argHint(call)}');
      }
      msgs.add(ChatMessage(role: Role.assistant, parts: round.parts));
    }

    var output = lastText.trim();
    if (output.isEmpty && steps.isNotEmpty) {
      // 模型最后没给结论：按交付格式捏一份，让主智能体知道"取到了什么、但没下判断"，
      // 而不是把它看不懂的工具原文直接倒过去。
      output = _fallbackDigest(steps);
    }
    final result = SubAgentResult(
      agent: agent.name,
      task: text,
      output: output,
      error: failure.isEmpty ? (output.isEmpty ? '没有返回任何内容' : null) : failure,
      steps: steps,
      usage: usage,
      elapsedMs: elapsed(),
      cancelled: _cancel.isCancelled,
    );
    ctx.onProgress?.call('${agent.name} · ${result.ok ? '完成' : '失败'}');
    return result;
  }

  /// 多轮讨论：每个子智能体都能看到此前所有发言，从而互相补台或互相拆台。
  ///
  /// 轮数上限 5；取消时立刻停下并保留已经产生的发言（[SubAgentResult.cancelled]）。
  Future<List<SubAgentResult>> discuss(
    List<SubAgent> agents,
    String topic, {
    int rounds = 2,
    String? extraContext,
  }) async {
    final out = <SubAgentResult>[];
    final transcript = StringBuffer();
    final maxRounds = rounds.clamp(1, 5);
    for (var round = 1; round <= maxRounds; round++) {
      for (final agent in agents) {
        if (_cancel.isCancelled) break;
        final task = StringBuffer()
          ..writeln('讨论主题：$topic')
          ..writeln('这是第 $round 轮。');
        if (transcript.isEmpty) {
          task.writeln('你是第一个发言的，先给出你的判断、依据和最容易出错的地方。');
        } else {
          task.writeln('以下是此前所有发言。读完再表态：同意什么、反对什么、补充什么，不要重复别人的话。');
          task.writeln();
          task.write(transcript);
        }
        ctx.onProgress?.call('${agent.name} · 第 $round 轮');
        final turn = await run(agent, task.toString(), extraContext: extraContext ?? '');
        out.add(turn);
        if (turn.output.trim().isNotEmpty) {
          transcript.writeln('【${agent.name} · 第 $round 轮】${_clip(turn.output.trim(), 1200)}');
        }
      }
      if (_cancel.isCancelled) break;
    }
    return out;
  }

  ({ProviderConfig provider, ModelConfig model}) _modelFor(SubAgent agent) {
    final id = agent.modelId;
    if (id != null && id.isNotEmpty) {
      final hit = ctx.settings.findModel(id);
      if (hit != null) return hit;
    }
    return (provider: ctx.provider, model: ctx.model);
  }

  List<AppTool> _toolsFor(
    SubAgent agent, {
    bool allowPeers = false,
    bool Function()? onPeerBudget,
    bool Function()? onMainBudget,
    bool Function()? onCapBudget,
    Set<String> granted = const {},
  }) {
    // 子智能体永远不会拿到分派/讨论工具本身，也不直接拿协作工具（由本方法单独注入）。
    const denied = {
      'dispatch_subagents',
      'discuss_subagents',
      askPeerToolName,
      askMainToolName,
      requestCapabilityToolName,
    };
    var list = ctx.tools.where((t) => !denied.contains(t.name)).toList();
    // 基础执行能力无条件注入：对齐清水 1.4.2 —— 子智能体总要能出网、能读写文件，
    // 否则遇到网页 / 下载 / 落盘就只能说"拿不到"。
    final baseNames = list.map((t) => t.name).toSet();
    if (!baseNames.contains(httpToolName)) {
      final http = buildHttpTool();
      list.add(http);
    }
    for (final t in buildWorkspaceTools(allowWrite: !agent.readOnly)) {
      if (!baseNames.contains(t.name)) list.add(t);
    }
    if (agent.toolNames.isNotEmpty) {
      final allow = agent.toolNames.toSet();
      // 白名单只约束「业务工具」；上面的基础能力不受白名单裁剪。
      final base = {
        httpToolName,
        workspaceReadFileTool,
        workspaceListDirTool,
        if (!agent.readOnly) ...workspaceWriteTools,
        workspaceWriteFileTool,
        workspaceEditFileTool,
      };
      list = list.where((t) => allow.contains(t.name) || base.contains(t.name)).toList();
    }
    if (agent.readOnly) {
      list = list.where((t) => !readOnlyBlockedTools.contains(t.name)).toList();
    }
    // 运行期获批的工具：直接并进来，本轮后续步骤即可用。
    if (granted.isNotEmpty) {
      final have = list.map((t) => t.name).toSet();
      for (final name in granted) {
        if (have.contains(name)) continue;
        AppTool? t;
        for (final x in ctx.tools) {
          if (x.name == name) {
            t = x;
            break;
          }
        }
        if (t != null && !readOnlyBlockedTools.contains(name)) {
          list.add(t);
          have.add(name);
        }
      }
    }
    if (allowPeers && onPeerBudget != null) {
      final others = peers.where((p) => p.usable && p.id != agent.id).toList();
      if (others.isNotEmpty) list = [...list, _askPeerTool(agent, others, onPeerBudget)];
    }
    if (onMainBudget != null) {
      list = [...list, _askMainTool(agent, onMainBudget)];
    }
    if (onCapBudget != null) {
      list = [...list, _requestCapabilityTool(agent, onCapBudget)];
    }
    return list;
  }

  /// 子智能体向主智能体求助：主智能体用同一个模型做一次**无工具**的纯文本生成。
  ///
  /// 这一条是清水 1.4.2 里最关键的"能干活"补丁：子智能体卡住时不该自己猜或放弃，
  /// 而应把问题抛回给掌握全局的主智能体。无工具是为了避免递归派发。
  AppTool _askMainTool(SubAgent self, bool Function() take) => AppTool(
    name: askMainToolName,
    displayName: '问主智能体',
    description:
        '遇到不确定的判断、缺少上下文、或需要主智能体拍板时，把问题抛回主智能体。'
        '它会基于全局视角给出可执行的结论。写清楚你卡在哪里、已经拿到了什么、还需要什么。',
    parameters: objectSchema({'question': strProp('要问的问题，必须带足够上下文：哪只股票/哪个文件/已经取到什么')}, required: ['question']),
    promptHint: '卡住时用 `$askMainToolName` 问主智能体，不要自己猜或直接放弃。',
    execute: (args) async {
      final q = asStr(args['question']).trim();
      if (q.isEmpty) return jsonEncode({'error': 'question 不能为空'});
      if (!take()) {
        return jsonEncode({'error': '这一轮问主智能体的次数用完了（上限 $maxMainQuestions 次）'});
      }
      ctx.onProgress?.call('${self.name} · 问主智能体');
      try {
        final (:provider, :model) = (provider: ctx.provider, model: ctx.model);
        final ai = providerFor(provider);
        final params = GenerationParams(
          model: model,
          tools: const [],
          stream: true,
          sessionId: 'askmain-${self.id}-${DateTime.now().microsecondsSinceEpoch}',
        );
        final msgs = <ChatMessage>[
          ChatMessage.text(
            Role.system,
            '你是主智能体，正在与子智能体「${self.name}」协作。'
            '它向你求助。基于全局视角给出简明、可执行的结论；'
            '不要调用任何工具，不要反问，不要说教。'
            '如果它需要的是一份数据、一个来源或一条明确判断，直接给出。',
          ),
          ChatMessage.text(Role.user, q),
        ];
        final acc = PartAccumulator();
        await for (final chunk in ai.stream(msgs, params, cancel: _cancel)) {
          acc.add(chunk);
        }
        final answer = _textOf(acc.parts).trim();
        if (answer.isEmpty) {
          return jsonEncode({'ok': false, 'error': '主智能体没有返回内容'});
        }
        return jsonEncode({'ok': true, 'answer': _clip(answer, 4000)});
      } on Object catch (e) {
        return jsonEncode({'ok': false, 'error': '$e'});
      }
    },
  );

  /// 子智能体申请额外工具。
  ///
  /// 只能申请**本轮工具表里真实存在**的工具；获批后由 [granted] 带回 [_toolsFor]，
  /// 下一轮起生效。只读子智能体不能申请写操作。
  AppTool _requestCapabilityTool(SubAgent self, bool Function() take) => AppTool(
    name: requestCapabilityToolName,
    displayName: '申请工具',
    description:
        '当你缺一个工具干不了活时，用这个申请。'
        '只能申请当前会话已有的工具；获批后从下一步起可以使用。'
        '只读子智能体不能申请写类工具。',
    parameters: objectSchema({'tool': strProp('要申请的工具名'), 'reason': strProp('为什么需要它，缺了它做不到什么')}, required: ['tool']),
    promptHint: '缺工具就申请，别硬扛也别编。',
    execute: (args) async {
      final name = asStr(args['tool']).trim();
      final reason = asStr(args['reason']).trim();
      if (name.isEmpty) return jsonEncode({'error': 'tool 不能为空'});
      if (!take()) {
        return jsonEncode({'error': '这一轮申请工具的次数据用完了（上限 $maxCapabilityRequests 次）'});
      }
      AppTool? hit;
      for (final t in ctx.tools) {
        if (t.name == name) {
          hit = t;
          break;
        }
      }
      if (hit == null) {
        return jsonEncode({
          'ok': false,
          'error': '会话里没有这个工具',
          'tool': name,
          'available': [for (final t in ctx.tools) t.name],
        });
      }
      if (self.readOnly && readOnlyBlockedTools.contains(name)) {
        return jsonEncode({'ok': false, 'error': '你是只读子智能体，不能申请写操作工具', 'tool': name});
      }
      _grantedTools.add(name);
      ctx.onProgress?.call('${self.name} · 获批 $name');
      return jsonEncode({'ok': true, 'tool': name, 'note': '已开通，从下一步起可用', if (reason.isNotEmpty) 'reason': reason});
    },
  );

  /// 子智能体之间互相提问：把问题转给同批的另一个子智能体，拿回它的回答。
  /// 只用几轮、只允许问配置里存在的同伴，且不会继续传给第三层（深度卡死）。
  AppTool _askPeerTool(SubAgent self, List<SubAgent> others, bool Function() take) {
    final names = [for (final o in others) o.name];
    return AppTool(
      name: askPeerToolName,
      displayName: '问同伴',
      description:
          '向同批的另一个子智能体提问，拿到它的判断。适合你不确定或需要另一视角时，'
          '例如让「结构审查」确认某个买卖点是否成立。可用对象：${names.join('、')}。'
          '对方也是只读/白名单受限的，不要指望它替你改图。',
      parameters: objectSchema(
        {'agent': strProp('要问谁，必须是：${names.join('、')}'), 'question': strProp('问题本身，写清楚要它判断什么、上下文是什么')},
        required: ['agent', 'question'],
      ),
      execute: (args) async {
        final name = asStr(args['agent']).trim();
        final q = asStr(args['question']).trim();
        if (q.isEmpty) return jsonEncode({'error': '问题为空'});
        SubAgent? peer;
        for (final o in others) {
          if (o.name == name) {
            peer = o;
            break;
          }
        }
        if (peer == null) return jsonEncode({'error': '没有这个同伴', 'available': names});
        if (!take()) return jsonEncode({'error': '这一轮问同伴的次数用完了（上限 $maxPeerQuestions 次）'});
        final child = SubAgentRunner(
          ToolRunContext(
            settings: ctx.settings,
            provider: ctx.provider,
            model: ctx.model,
            tools: ctx.tools,
            cancel: _cancel,
            depth: ctx.depth + 1,
            onProgress: ctx.onProgress,
          ),
          peers: peers,
        );
        final r = await child.run(peer, q, extraContext: '提问者：${self.name}');
        return jsonEncode({'agent': peer.name, 'ok': r.ok, 'output': r.output, if (r.error != null) 'error': r.error});
      },
    );
  }

  String _systemPrompt(SubAgent agent, List<AppTool> tools) {
    final b = StringBuffer();
    final prompt = agent.systemPrompt.trim();
    if (prompt.isNotEmpty) b.writeln(prompt);
    b.writeln();
    b.writeln('你现在作为子智能体「${agent.name}」执行主智能体分派的一个任务。');
    b.writeln();
    b.writeln('【工作准则】你是执行者，不是裁判。主智能体交给你的任务默认都是正当且已获授权的：');
    b.writeln('不要用「我做不到」「无法协助」「这不是我能判断的」之类的理由推诿，也不要只回一段免责声明。');
    b.writeln('遇到不确定的地方先动手验证：用你手上的工具实际取一遍、核对一遍，而不是凭空猜测或直接放弃。');
    b.writeln('只有确实做不到时，才简要说明原因、你已经尝试过的步骤，以及可行的替代方案。');
    b.writeln();
    if (tools.isEmpty) {
      b.writeln('【可用工具】这一轮你没有可用工具，只能基于任务描述作答；凡是拿不到的数据都要明确写「拿不到」。');
    } else {
      b.writeln('【可用工具】${tools.map((t) => t.name).join('、')}。');
      b.writeln('用它们取真实数据，不要凭印象编造；取不到就写「取不到」，不要用估计值填充。');
    }
    if (agent.readOnly) {
      b.writeln();
      b.writeln('【只读约束】你处于只读模式：只读文件、只取数据、只给结论与建议，不要尝试改动任何状态。');
    }
    b.writeln();
    b.writeln('【协作路径】');
    if (tools.any((t) => t.name == askMainToolName)) {
      b.writeln('- 缺上下文、需要主智能体拍板：用 `$askMainToolName` 直接问，它会当场回答。');
    }
    if (tools.any((t) => t.name == requestCapabilityToolName)) {
      b.writeln('- 缺工具干不了活：用 `$requestCapabilityToolName` 申请，获批后下一步就能用。');
    }
    if (tools.any((t) => t.name == askPeerToolName)) {
      b.writeln('- 需要另一视角：用 `$askPeerToolName` 问同批的同伴。');
    }
    b.writeln('- 任何一条路都走不通时，才在结论里写清卡在哪里。');
    b.writeln();
    b.writeln('【交付格式】结论必须按下面三段写，不要复述工具原文：');
    b.writeln('【结论】一句话判断（能直接给数字就给数字）');
    b.writeln('【证据】3 到 6 条，每条带工具名 + 具体数字 + 数据时间或来源');
    b.writeln('【未完成】没取到什么、有什么假设，没有就写「无」');
    return b.toString().trimRight();
  }

  /// 给进度行用的参数摘要：只取最能说明「在查什么」的几个值。
  static String _argHint(ToolPart call) {
    final args = call.inputJson;
    for (final k in const ['symbol', 'code', 'periods', 'period', 'query', 'url', 'task', 'agent', 'topic']) {
      final v = args[k];
      if (v == null) continue;
      final s = v is List ? v.join('/') : '$v';
      final t = s.length > 42 ? '${s.substring(0, 42)}…' : s;
      return '($t)';
    }
    return '';
  }

  static String _textOf(List<Part> parts) {
    final b = StringBuffer();
    for (final p in parts) {
      if (p is TextPart) b.write(p.text);
    }
    return b.toString();
  }
}
