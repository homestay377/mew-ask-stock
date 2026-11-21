# 子智能体（P1）

主智能体可以把互相独立的工作分派给「子智能体」：每个子智能体有自己的系统提示词、可选的模型、工具白名单，只读的还会被剔掉写操作。参考的设计来自 [ds7891/-](https://github.com/ds7891/-)（同为 AGPL-3.0，Kotlin/Compose）的子 agent 实现；这里是按 MewHub 的 Dart 接口重写，不是移植。

## 为什么需要 ToolRunContext

MewHub 的工具契约是 `execute(args)` —— 只有参数，拿不到模型、设置、工具表、取消令牌。给每个工具加参数会牵动所有工具和所有调用点。

所以 `ChatController._runTools` 用 `runZoned` 注入一份 `ToolRunContext`：

```dart
final out = await runWithToolContext(runCtx, () => tool.execute(args)).timeout(limit);
```

- 没用到它的工具完全不受影响（Zone 里多一个值而已）。
- 分派工具用 `currentToolRun()` 取；不在生成过程中时为 `null`，工具回一个明确的错误。
- 分派工具的等待上限放宽到 10 分钟，其余工具仍是 3 分钟。

## 文件

| 文件 | 作用 |
|---|---|
| `lib/agents/tool_run_context.dart` | 上下文对象 + Zone 注入 |
| `lib/agents/sub_agent.dart` | 配置模型、只读写工具黑名单、5 个内置条目、给模型看的目录 |
| `lib/agents/sub_agent_store.dart` | `sub_agents.json` 持久化 + 内置种子标记 |
| `lib/agents/sub_agent_runner.dart` | 单任务引擎：独立提示词、白名单、24 步上限、1 层嵌套、单工具 3 分钟 |
| `lib/agents/sub_agent_tools.dart` | `dispatch_subagents`：同批并行、`wait_for_others` 后置 |
| `lib/ui/pages/sub_agents_page.dart` | 设置页：增删改、启停、模型、白名单、只读 |

## 边界

- **子智能体永远拿不到 `dispatch_subagents`**：一层就够，避免无限套娃。
- 只读 = 白名单再减 `readOnlyBlockedTools`（`chart_annotate`、`stock_panel_show`）。`SubAgentRunner._toolsFor` 是唯一入口，UI 里勾错也不会漏出去。
- 子智能体没有自己的多模态历史：一次任务 = 一条 system + 一条 user，工具结果留在它自己的消息里。
- 并行是在 Dart 层面 `Future.wait`，同时打同一个供应商的多个请求；供应商限流时会被自己的错误处理接住，不会影响其他任务。
- 子智能体的 token 用量记在结果的 `tokens` 里，**不进** 主对话的用量统计（还没做归集）。

## 还没做（P2/P3）

- `discuss_subagents`：多轮讨论
- 过程实时可见（`ToolRunContext.onProgress` 已经留好口子，界面上还没消费）
- trace 卡片：可折叠的步骤、耗时、token
- 子智能体之间互相提问（协作工具）