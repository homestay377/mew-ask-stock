# 虚拟屏（Virtual Display）

让问股在**一块看不见的屏**上打开别的 App（同花顺、雪球、通达信、开盘啦…），读界面、点按钮、翻页，
**全程不占用你的主屏**。这是 Mika 那条路的等价实现。

## 1. 为什么必须是虚拟屏

普通 App 只有无障碍，只能操作你眼前这块屏：你一滑动、一切换，它就瞎了，而且它一动你就被打断。
虚拟屏是系统给的一块独立显示器：

- App 在上面正常渲染，无障碍树能读到（`getWindowsOnAllDisplays[displayId]`）；
- 注入的触摸只投到这块屏（`InputEvent.setDisplayId`）；
- 你的主屏完全不受影响，可以边聊边让它干活。

代价：**建虚拟屏需要 shell 身份（uid 2000）**，普通应用签名拿不到。所以要有 Shizuku 或无线调试配对。

## 2. 结构

```
Flutter（模型循环）
   │  MethodChannel: .../virtual_display          MethodChannel: .../mini_phone
   ▼                                              ▼
VirtualDisplayBridge                        MiniPhoneBridge（无障碍）
   │  AIDL IShellDisplay                         │  读树 / 手势 / 按键（可指定 displayId）
   ▼                                            ▼
ShellDisplayService（跑在 shell 身份进程）
   ├─ Shizuku UserService  ← ShizukuChannel 绑定
   └─ app_process 助手      ← 无线调试（P2，暂未接）
```

关键点：**Kotlin 只做原子动作**（建屏、启动、注入、释放），决策留在 Flutter 的模型循环里。
不做 Mika 那套 shell 侧 Agent，避免两套智能体打架。

## 3. 建屏参数（都有来历，别乱改）

| 项 | 值 | 为什么 |
|---|---|---|
| 标志位 | `PUBLIC\|OWN_CONTENT_ONLY\|SUPPORTS_TOUCH\|ROTATES_WITH_CONTENT\|DESTROY_CONTENT_ON_REMOVAL` | 基础六项 |
| 安卓 13+ | `+TOUCH_FEEDBACK_DISABLED` | 虚拟屏上不要触摸涟漪 |
| 可信时 | `+TRUSTED\|OWN_DISPLAY_GROUP\|ALWAYS_UNLOCKED` | 自成显示组、不随主屏锁屏 |
| 安卓 14+ 可信 | `+OWN_FOCUS\|STEAL_TOP_FOCUS_DISABLED` | 有焦点但不抢主屏焦点 |
| 失败降级 | 先 trusted 再 untrusted | 有些系统 shell 没有 `ADD_TRUSTED_DISPLAY`，带 TRUSTED 会 SecurityException |
| 窗口模式 | `setWindowingMode(id, 1)` 全屏 | 否则部分系统会建在 freeform 里，App 缩成小窗、坐标全偏 |
| 输入法 | `setDisplayImePolicy(id, 0 /*LOCAL*/)` | 输入法弹在虚拟屏上，不弹到你主屏 |
| 启动 App | `ActivityOptions.setLaunchDisplayId` + 反射 `startActivityAsUser(12 参)`，失败退 `am start --display` | 直接 Intent 带不了屏号 |
| 注入 | `injectInputEvent(event, mode)` 前先 `event.setDisplayId(id)` | 按键按焦点路由，不认 event 上的 displayId |
| 帧率 | ≤10 帧/秒（100ms 节流） | 每帧都是整屏合成，太高掉电 |

## 4. 工具

| 工具 | 作用 |
|---|---|
| `vd_status` | 现在能不能用：Shizuku 跑没跑、授权没授权、屏建没建 |
| `vd_prepare` | 走一遍 授权 → 绑定 → 建屏；缺哪步就说哪步 |
| `vd_open` | 打开 App（**中文名或包名都行**，名字→包名由 PackageManager 解析） |
| `vd_apps` | 列已装 App；默认只列行情相关，可 `all=true` |
| `vd_observe` / `vd_find` | 读那块的界面（元素 + ref + 坐标） |
| `vd_tap` / `vd_scroll` / `vd_type` / `vd_back` | 点、滚、输入、返回 |

写动作后**自动再读一次屏**，模型不用多花一轮确认。

## 5. 两条身份路线

| 路线 | 状态 | 说明 |
|---|---|---|
| **A. Shizuku** | ✅ 已实现 | 官方 API 绑定 UserService；binder 的 uid 必须是 2000/0，否则拒收 |
| **B. 无线调试 app_process** | 🔜 未接 | `ShellContext` 已写好（`ActivityThread.systemMain` 自建 Context），差 adbd 客户端与配对流程 |

A 和 B **共用同一个 `ShellDisplayService`**，所以 B 只是"换一个 binder 来源"，不影响上面的工具。

Shizuku 状态机（`ShizukuChannel`）：`not_installed / not_running / need_permission / binding / ready / failed`，
每个状态都有对应的用户动作，**不会静默失败**。

## 6. 数据口径（重要）

虚拟屏读到的是**界面显示值**，不是行情接口：

- 能走 `stock_kline` / `analyze_chan` / `stock_levels` 的，**优先走接口**（快、可复现、不烧 token）；
- 虚拟屏是"接口拿不到才用"的补充（行业资金流、龙虎榜席位、F10 里没 API 的字段、涨停复盘）；
- 引用界面值时**必须标注来源**，不许把界面值当成接口数据；
- 两者冲突时以接口为准，并把差异如实说出来。

## 7. 已知限制

- **同一个 App 不能同时在两块屏上**：你在主屏用着同花顺时，虚拟屏打不开它（返回 `in_use_on_main`）。
- 部分 App 在非默认显示器上会闪退或白屏（同花顺在 Mika 那边实测正常，我们这台还没验）。
- 虚拟屏的截图**不是**数据源，只用来兜底（App 用了不暴露无障碍的自绘界面时）。
- 支付、登录验证码不自动填，交给用户。
- Shizuku 服务重启会导致 binder 断开，需要重绑（工具会提示）。

## 8. 排查

1. `vd_status`：先确认 Shizuku 是 `ready`；
2. `vd_prepare`：确认 `display.phase == ready`；
3. 打开 App 后 `vd_observe` 若有 `displayId` 但没元素：可能 App 还没画完，等 1–2 秒重试；
4. 坐标全偏：检查 `setWindowingMode` 是否成功（少数系统会拒绝，退 `wm` 命令也在日志里）。

日志标签：`ShellDisplay`（shell 侧）、`ShizukuChannel`、`VirtualDisplayHost`、`VirtualDisplayMgr`。
