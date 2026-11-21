import 'dart:convert';

import '../ai/factory.dart';
import '../ai/message.dart';
import '../ai/provider.dart';
import '../ai/provider_config.dart';
import '../chat/accumulator.dart';
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
  SubAgentRunner(this.ctx);

  final ToolRunContext ctx;

  /// 单个任务最多几轮工具来回。
  static const maxSteps = 24;

  /// 子智能体不能再派子智能体，深度直接卡在 1 层。
  static const maxDepth = 1;

  static const _toolTimeout = Duration(minutes: 3);
  static const _stepOutputLimit = 4000;

  Future<SubAgentResult> run(SubAgent agent, String task, {String extraContext = ''}) async {
    final started = DateTime.now();
    int elapsed() => DateTime.now().difference(started).inMilliseconds;
    final text = task.trim();
    if (text.isEmpty) {
      return SubAgentResult(agent: agent.name, task: task, output: '', error: '任务描述为空', elapsedMs: 0);
    }
    if (ctx.depth >= maxDepth) {
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

    final tools = _toolsFor(agent);
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
        ctx.onProgress?.call('${agent.name} · ${call.name}');
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

  List<AppTool> _toolsFor(SubAgent agent) {
    // 子智能体永远不会拿到分派工具本身：一层就够，避免无限套娃。
    var list = ctx.tools.where((t) => t.name != 'dispatch_subagents').toList();
    if (agent.toolNames.isNotEmpty) {
      final allow = agent.toolNames.toSet();
      list = list.where((t) => allow.contains(t.name)).toList();
    }
    if (agent.readOnly) {
      list = list.where((t) => !readOnlyBlockedTools.contains(t.name)).toList();
    }
    return list;
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

  static String _textOf(List<Part> parts) {
    final b = StringBuffer();
    for (final p in parts) {
      if (p is TextPart) b.write(p.text);
    }
    return b.toString();
  }
}
