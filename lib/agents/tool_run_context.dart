import 'dart:async';

import '../ai/provider_config.dart';
import '../core/net.dart';
import '../data/settings.dart';
import '../tools/tool.dart';

/// 一次工具调用除了参数之外还需要的东西。
///
/// MewHub 的工具契约是 `execute(args)`，这对无状态工具够用，但「再开一次
/// 模型调用」的工具需要拿到当前模型、设置、可用工具表和取消令牌。给每个
/// 工具加参数会牵动所有工具和所有调用点，所以由 ChatController 在调用工具
/// 时用 Zone 注入这一份上下文；没用到它的工具完全不受影响。
class ToolRunContext {
  ToolRunContext({
    required this.settings,
    required this.provider,
    required this.model,
    required this.tools,
    required this.cancel,
    this.depth = 0,
    this.onProgress,
    this.sessionKey,
  });

  final AppSettings settings;

  /// 主智能体当前用的供应商与模型；子智能体没指定模型时沿用它。
  final ProviderConfig provider;
  final ModelConfig model;

  /// 主智能体这一轮拿到的全部工具，子智能体按白名单从这里取。
  final List<AppTool> tools;
  final CancelToken cancel;

  /// 0 表示主智能体；子智能体是调用方的 depth + 1。
  final int depth;

  /// 子智能体的过程行（P2 用来实时显示，目前可以留空）。
  final void Function(String line)? onProgress;

  /// 当前会话标识。团队任务板按它挂载，`add_team_tasks` 靠它找回同一张板。
  /// 为空时退化成"最近一次分派"的单槽模式。
  final String? sessionKey;
}

final Object _zoneKey = Object();

/// 当前正在执行的工具上下文；不在对话生成过程中时为 null。
ToolRunContext? currentToolRun() => Zone.current[_zoneKey] as ToolRunContext?;

/// 在 [ctx] 的作用域里执行 [body]，用于包住一次工具调用。
Future<T> runWithToolContext<T>(ToolRunContext ctx, Future<T> Function() body) =>
    runZoned(body, zoneValues: {_zoneKey: ctx});
