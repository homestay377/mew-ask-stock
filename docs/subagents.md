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
| `lib/agents/sub_agent_runner.dart` | 单任务引擎：独立提示词、白名单、24 步上限、1 层嵌套、单工具 3 分钟；`ask_main_agent` / `request_capability` / `ask_peer` 三个协作工具 |
| `lib/agents/team_board.dart` | 团队任务板：`task_id` + `depends_on` 依赖图、前置失败自动跳过、依赖产出按预算转交 |
| `lib/agents/sub_agent_tools.dart` | `dispatch_subagents`（建板并跑 DAG）、`discuss_subagents`、`add_team_tasks`（往同一张板追加） |
| `lib/tools/http_tool.dart` | `http_request`：子智能体的无条件出网能力 |
| `lib/tools/workspace_tools.dart` | `workspace_read_file` / `write_file` / `edit_file` / `list_dir`，路径限制在根目录白名单内 |
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

## P4 补的东西：让它真能干活

P3 之后子智能体仍有一个硬伤：它只能取数，取不到就编，编完给一句话。对照清水 1.4.2 拆包结果，缺的是**基础执行能力**和**求助通道**，不是提示词技巧。

### 基础执行能力（无条件注入）

`http_request` 与 `workspace_*` 是子智能体的基础能力，**不受工具白名单裁剪**，只受「只读」约束：

- `http_request`：GET/POST/PUT/PATCH/DELETE/HEAD，自定义 header 与 body；`save_to` 可把响应落盘。
  512 KB 读取上限，正文默认 8000 字符，二进制（图片/zip/APK）只返回大小与落盘指引，不会把上下文撑爆。
  非 2xx **不抛异常**：抓 404 页面、看错误体是正常需求。
- `workspace_read_file` / `workspace_write_file` / `workspace_edit_file` / `workspace_list_dir`：
  路径归一化后限制在允许的根目录内（应用支持目录、`/storage/emulated/0`、`/data/local/tmp`、临时目录），越界直接拒绝。
  只读子智能体只拿到「读文件 + 列目录」两件套。

### 协作通道

| 工具 | 作用 | 上限 |
|---|---|---|
| `ask_main_agent` | 缺上下文/要拍板时问主智能体。主智能体用**无工具**纯文本作答，避免递归派发 | 每任务 3 次 |
| `request_capability` | 缺工具时申请。只批准会话里真实存在的工具；只读子智能体不能申请写操作。获批后**下一步立即生效** | 每任务 3 次 |
| `ask_peer` | 转问同批同伴 | 每任务 3 次 |

关于「立刻生效」：`run()` 的循环里，只要 `_grantedTools` 非空就每轮重算工具表并重建 `GenerationParams`，
否则模型会一直看到旧的工具列表，申请等于白申请。

### 团队任务板（DAG，取代 `wait_for_others` 二段式）

```json
{
  "assignments": [
    {"task_id": "t1", "agent": "行情侦察", "task": "..."},
    {"task_id": "t2", "agent": "结构审查", "task": "...", "depends_on": ["t1"]},
    {"task_id": "t3", "agent": "策略方案", "task": "...", "depends_on": ["t1", "t2"]}
  ]
}
```

- 依赖全部 `done` 的任务立刻**并行**开工；
- 前置 `failed` / `skipped` 时，下游标 `skipped` 并写明原因，**不再消耗 token**；
- 前置产出按 **2500 字/任务、8000 字总量** 的预算自动拼给下游；
- 依赖只能引用排在它前面的任务，引用不存在或成环会被判死。

老写法兼容：`wait_for_others: true` 且没写 `depends_on` → 自动转成「依赖前面全部任务」。

### 运行期追加

`add_team_tasks` 把新任务并入同一张板，可以 `depends_on` 引用板上已有的 id，不重跑已完成的活。
板按 `ToolRunContext.sessionKey`（会话 id）挂在内存里，App 重启即清空——团队任务本来就是一次会话内的事。

**诚实边界**：目前追加发生在 `dispatch_subagents` 已经返回之后，不会与仍在执行的子任务真正并行。
真正做到「中途插入」需要把 dispatch 改成后台任务，改动面太大，留到下一步。

### 提示词

三段硬约束，都是清水 1.4.2 里实测存在的：

1. **工作准则**：执行者不是裁判；不许用「我做不到」「无法协助」推诿；先动手验证再说话；真做不到才说明原因与替代方案。
2. **交付格式**：`【结论】/【证据】/【未完成】` 三段，不许复述工具原文。
3. **兜底**：跑满 24 步仍没结论时，按同样的格式声明「取了几次、成功几次、涉及哪些工具、失败哪些」，不再把工具原文整段倒给主控。

### 只读边界变化

`readOnlyBlockedTools` 增加 `workspace_write_file`、`workspace_edit_file`。
内置条目里 **行情侦察**、**资料研究** 放开只读（它们本来就要出网取数），
结构审查 / 策略方案 / 数据核验 保持只读，图文标注保持可写。

### 还没做

- dispatch 后台化，实现真正的运行期并行追加；
- 逐 token 实时输出 + 单独终止某一个子智能体（现在的进度行仍是 `onProgress` 字符串）；
- 子智能体 token 归集进主对话用量统计。

## P5：界面要真能看见

上一版任务板只在「智能体团队」面板里，而且是打开瞬间的快照——分派跑起来界面毫无反应，纯假界面。对着清水 1.4.2 的截图逐条比，缺的是三处：

### 1. 聊天流里的分派卡片本身就是任务板

`ToolCard` 的分派视图优先读 `meta.board`（dispatch 运行期一路推上来的快照），所以任务还在跑的时候就能看到：

```
t1 · 研究员   [运行中]   ← spinner
t2 · 研究员   [运行中]
t3 · 研究员   [运行中]
t4 · 审查员   [等待前置]
依赖：t1、t2、t3                    [终止]
```

不再是等整个分派结束才蹦一段 JSON。

### 2. 实时数据链

```
ToolRunContext.onBoardUpdate
  → chat_controller.pushBoard 写进 ToolPart.meta['board']
  → dispatch / add_team_tasks 每次状态变化推一次
  → 聊天卡片按 parts 变化重建
```

`runTeamBoard` 在每一批任务标成 `running` 之后立刻推一次，所以「谁刚开工」是马上可见的，不是等它跑完。

面板（`sub_agent_sheet`）另外用 400ms 轮询兜底，因为它不随 parts 重建。

### 3. 单独终止

- `TeamBoard` 生成 `runId`，每条任务 JSON 带 `run_key = runId/taskId`；
- `team_board.dart` 维护 `_runningTasks` 注册表，`cancelTeamTask(key)` 精准停一个；
- `_runOne` 给每个子任务建独立 `CancelToken`，并联动全局取消（全局停 = 全部停）；
- `SubAgentRunner` 新增 `cancelOverride`，内部所有取消判断走 `_cancel`。

界面在运行中的任务行右侧给终止按钮，点它只停这一条，同批其他任务继续。

### 4. 运行中横幅

会话里有未返回的分派时，输入框上方显示：

```
[团队] 团队运行中 · 发送的消息会直接交给团队        查看智能体团队 ›
```

点它直接打开任务板；输入框里发的话照旧走主智能体（它能看到任务板状态并决定追加）。

### 已知边界

- 追加（`add_team_tasks`）仍发生在 dispatch 返回之后，不与仍在跑的子任务真并行；
- 单独终止是把该子任务的流式请求中断，模型已经产生的 token 不会回收；
- token 合计只统计子智能体自己那一轮，不含主控。
