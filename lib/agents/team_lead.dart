import '../ai/factory.dart';
import '../ai/message.dart';
import '../ai/provider.dart';
import '../chat/accumulator.dart';
import '../tools/tool.dart';
import 'team_board.dart';
import 'tool_run_context.dart';

/// 团队运行期间的「追问 lead」通道。
///
/// 为什么需要单独一条：`dispatch_subagents` 还在执行时，主对话的生成循环是被它
/// 占住的，用户这时候发消息只会排在后面。清水 1.4.2 的做法是开一条独立通道——
/// 拿当前任务板快照 + 用户问题，直接问主模型，允许它用 `add_team_tasks` 追加任务。
///
/// 这里同样不碰主循环：用同一个模型做一次独立生成，最多 3 轮工具调用。
Future<String> askTeamLead({
  required ToolRunContext ctx,
  required TeamBoard board,
  required String question,
  List<AppTool> extraTools = const [],
  int maxRounds = 3,
}) async {
  final q = question.trim();
  if (q.isEmpty) return '';

  final params = GenerationParams(
    model: ctx.model,
    tools: [for (final t in extraTools) t.spec],
    stream: true,
    sessionId: 'team-lead-${DateTime.now().microsecondsSinceEpoch}',
  );
  final msgs = <ChatMessage>[ChatMessage.text(Role.system, _leadPrompt(board)), ChatMessage.text(Role.user, q)];
  final ai = providerFor(ctx.provider);
  final byName = {for (final t in extraTools) t.name: t};
  var out = '';
  for (var round = 0; round < maxRounds; round++) {
    if (ctx.cancel.isCancelled) break;
    final acc = PartAccumulator();
    await for (final chunk in ai.stream(msgs, params, cancel: ctx.cancel)) {
      acc.add(chunk);
    }
    final text = _textOf(acc.parts);
    if (text.trim().isNotEmpty) {
      out = text;
    }
    final pending = acc.pendingTools;
    if (pending.isEmpty) {
      msgs.add(ChatMessage(role: Role.assistant, parts: acc.parts));
      break;
    }
    for (final call in pending) {
      final tool = byName[call.name];
      String result;
      if (tool == null) {
        result = '{"error":"这一轮没有这个工具"}';
      } else {
        // add_team_tasks 内部走 Zone 拿上下文，这里包一层。
        result = await runWithToolContext(ctx, () => tool.execute(call.inputJson));
      }
      final idx = acc.parts.indexWhere((p) => identical(p, call));
      if (idx >= 0) {
        acc.parts[idx] = call.copyWith(output: result);
      }
      ctx.onProgress?.call('lead · ${call.name}');
    }
    msgs.add(ChatMessage(role: Role.assistant, parts: acc.parts));
  }
  return out.trim();
}

String _textOf(List<Part> parts) {
  final b = StringBuffer();
  for (final p in parts) {
    if (p is TextPart) b.write(p.text);
  }
  return b.toString();
}

String _leadPrompt(TeamBoard board) {
  final b = StringBuffer()
    ..writeln('你是「智能体团队」的主智能体（lead）。团队正在执行任务，用户在运行过程中向你询问进度、提出调整或追加任务。')
    ..writeln()
    ..writeln('1. 只依据下面给出的任务板与实时状态回答，禁止编造未发生的进度或结果。')
    ..writeln('2. 用户要求追加任务时，调用 add_team_tasks 提交；新任务会并入同一张任务板并立即执行。')
    ..writeln('3. 你无法取消正在运行的任务；用户要停某个子智能体，请让他在任务卡上点终止。')
    ..writeln('4. 回答要短：先给结论，再给依据（哪条任务、什么状态）。不要复述整张任务板。')
    ..writeln()
    ..writeln('【当前任务板】');
  if (board.tasks.isEmpty) {
    b.writeln('（空）');
  }
  for (final t in board.tasks) {
    final deps = t.dependsOn.isEmpty ? '' : '，依赖 ${t.dependsOn.join('、')}';
    final body = t.task.replaceAll('\n', ' ').trim();
    final short = body.length <= 120 ? body : '${body.substring(0, 120)}…';
    final extra = <String>[
      if (t.liveOutput.trim().isNotEmpty) '正在写：${_clip(t.liveOutput.replaceAll('\n', ' '), 120)}',
      if (t.liveSteps.isNotEmpty) '已跑 ${t.liveSteps.length} 步',
      if (t.result != null && t.result!.output.trim().isNotEmpty)
        '产出：${_clip(t.result!.output.replaceAll('\n', ' '), 160)}',
      if (t.error != null && t.error!.isNotEmpty) '错误：${t.error}',
    ];
    b.writeln(
      '- ${t.id} · ${t.agentName} [${t.status.name}]（$short）$deps${extra.isEmpty ? '' : ' ｜ ${extra.join('；')}'}',
    );
  }
  return b.toString().trimRight();
}

String _clip(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';
