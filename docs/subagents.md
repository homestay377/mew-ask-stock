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

## 还没做（P3）

- 子智能体之间互相提问（协作工具）
- trace 的展开态：现在能一眼看到每个子智能体的步数/耗时/token 和结论开头，但看不到逐条工具调用的细节（`steps` 里其实有，只是界面没铺开）
- 流程上仍是一层：子智能体拿不到 `dispatch_subagents`

## P2 补的东西

- `discuss_subagents`：最多 4 个参与者、1–5 轮，串行发言，每轮都能看到此前所有发言；分歧比结论更有用。
- 过程实时可见：`ToolRunContext.onProgress` 的每一行写进 `ToolPart.meta.progress`，界面在工具还没返回时就能看到「谁开工了、谁完成了」。
- `ToolCard` 对这两个工具显示摘要行（ok/失败、步数、耗时、token、结论开头），完整 JSON 仍在展开区。
- 分派与讨论的等待上限都是 15 分钟（普通工具 3 分钟）。
## P3 补的东西

- **互相提问**：子智能体在深度允许时多一个 `ask_peer` 工具，可以把问题转给同批的另一个同伴（不能问自己，每个任务最多 3 次）。深度：主控 0 → 子智能体 1 → 被问的同伴 2，到 2 就不再往下传。
- **团队面板**：聊天页抬头的人形按钮打开，列出「主控 + 子智能体」成员卡（只读/停用标签、正在干什么、最近一次的工具调用次数），以及本会话里的「共享任务」，点开可看每个子智能体的产出。
- **逐工具可见**：进度行现在带参数摘要（股票代码/周期/查询词），展开工具卡仍能看到完整 JSON；面板里按成员统计调用次数。
- **内置加了一位「数据核验」**：只读，专门核对数据新鲜度（`fetched_at`/`closed`/`from_cache`/`quality`）、旧价位当现状、跨周期矛盾、把「取不到」写成数字这四类问题。它对应「验证模块」，不需要新数据源。

## 还没做的，以及为什么

- **指数/板块/赚钱效应**：「市场模块」需要有可靠的指数与板块数据接口。现在只有个股 K 线（腾讯/新浪/东财）与基本面，没有板块强弱、涨停家数这类数据。硬写就等于让模型编数字，所以不做。
- **资讯时效**：没有接入新闻源，`search_web` 只在配置了搜索服务时可用。接入后可以再加「资讯核对」子智能体，届时再说。
