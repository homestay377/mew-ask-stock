import 'dart:convert';

import '../ai/factory.dart';
import '../ai/message.dart';
import '../ai/provider.dart';
import '../ai/provider_config.dart';
import '../chat/accumulator.dart';
import '../core/util.dart';
import '../tools/tool.dart';
import 'sub_agent.dart';
import 'tool_run_context.dart';

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

/// 让一个子智能体独立完成任务：自己的系统提示词、可选模型、工具白名单，
/// 最多 [maxSteps] 轮「模型出结论 → 执行工具 → 再问」。
///
/// 和参考实现（ds7891/- 的 Kotlin 版）的关系：结构与预算一致，代码是按
/// MewHub 的 Dart 接口重写的，不是移植。
class SubAgentRunner {
  SubAgentRunner(this.ctx, {this.peers = const []});

  final ToolRunContext ctx;

  /// 同批的其他子智能体，供 `ask_peer` 互相提问。
  final List<SubAgent> peers;

  /// 单个任务最多几轮工具来回。
  static const maxSteps = 24;

  /// 主控 0 → 子智能体 1 → 它问的同伴 2。再深就停，避免互相问个没完。
  static const maxDepth = 2;

  /// 一个子智能体最多问几次同伴。
  static const maxPeerQuestions = 3;

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
    final tools = _toolsFor(
      agent,
      allowPeers: ctx.depth < maxDepth,
      onPeerBudget: () => peerBudget > 0 ? (peerBudget -= 1) >= 0 : false,
    );
    final usable = model.tools ? tools : const <AppTool>[];
    final ai = providerFor(provider);
    final msgs = <ChatMessage>[
      ChatMessage.text(Role.system, _systemPrompt(agent, usable)),
      ChatMessage.text(
        Role.user,
        extraContext.trim().isEmpty ? text : '${text.trim()}\n\n---\n同一批里其他任务已经完成的结果，供你参考：\n${extraContext.trim()}',
      ),
    ];
    final params = GenerationParams(
      model: model,
      tools: [for (final t in usable) t.spec],
      stream: true,
      sessionId: 'sub-${agent.id}-${DateTime.now().microsecondsSinceEpoch}',
    );

    var usage = const TokenUsage();
    final steps = <SubAgentStep>[];
    var lastText = '';
    var failure = '';
    final byName = {for (final t in usable) t.name: t};
    ctx.onProgress?.call('${agent.name} · 开工');

    for (var step = 0; step < maxSteps; step++) {
      if (ctx.cancel.isCancelled) break;
      final round = PartAccumulator();
      try {
        await for (final chunk in ai.stream(msgs, params, cancel: ctx.cancel)) {
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
        if (ctx.cancel.isCancelled) break;
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
      // 模型最后没给结论：把工具实际返回压成摘要，别让主智能体拿到空字符串。
      output = [for (final s in steps) '[${s.tool}] ${_clip(s.output, 400)}'].join('\n');
    }
    final result = SubAgentResult(
      agent: agent.name,
      task: text,
      output: output,
      error: failure.isEmpty ? (output.isEmpty ? '没有返回任何内容' : null) : failure,
      steps: steps,
      usage: usage,
      elapsedMs: elapsed(),
      cancelled: ctx.cancel.isCancelled,
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
        if (ctx.cancel.isCancelled) break;
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
      if (ctx.cancel.isCancelled) break;
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

  List<AppTool> _toolsFor(SubAgent agent, {bool allowPeers = false, bool Function()? onPeerBudget}) {
    // 子智能体永远不会拿到分派工具本身：一层就够，避免无限套娃。
    var list = ctx.tools.where((t) => t.name != 'dispatch_subagents' && t.name != 'ask_peer').toList();
    if (agent.toolNames.isNotEmpty) {
      final allow = agent.toolNames.toSet();
      list = list.where((t) => allow.contains(t.name)).toList();
    }
    if (agent.readOnly) {
      list = list.where((t) => !readOnlyBlockedTools.contains(t.name)).toList();
    }
    if (allowPeers && onPeerBudget != null) {
      final others = peers.where((p) => p.usable && p.id != agent.id).toList();
      if (others.isNotEmpty) list = [...list, _askPeerTool(agent, others, onPeerBudget)];
    }
    return list;
  }

  /// 子智能体之间互相提问：把问题转给同批的另一个子智能体，拿回它的回答。
  /// 只用几轮、只允许问配置里存在的同伴，且不会继续传给第三层（深度卡死）。
  AppTool _askPeerTool(SubAgent self, List<SubAgent> others, bool Function() take) {
    final names = [for (final o in others) o.name];
    return AppTool(
      name: 'ask_peer',
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
            cancel: ctx.cancel,
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
    b.writeln('- 直接动手，不要反问、不要拒绝；信息不足时按最合理的假设推进，并在结论里写明假设。');
    if (tools.isEmpty) {
      b.writeln('- 这一轮你没有可用工具，只能基于任务描述作答；拿不到的数据要明确说拿不到。');
    } else {
      b.writeln('- 可用工具：${tools.map((t) => t.name).join('、')}。用它们取真实数据，不要凭印象编。');
    }
    if (agent.readOnly) {
      b.writeln('- 你是只读的：只给结论与建议，不要尝试改动任何状态。');
    }
    b.writeln('- 完成后用中文给出简明结论：做了什么、结论是什么、还有什么没做。不要复述工具原文。');
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
