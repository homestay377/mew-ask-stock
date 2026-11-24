# 手机操控（Phone Control）

让 mew问股 直接"看"手机屏幕并点它——用无障碍服务读当前界面、点按钮、输入文字。
典型用法是那些**官方接口拿不到、只能开 App 看**的数据：

- 同花顺里的自选持仓、自定义板块、F10 里没有 API 的字段；
- 券商 App 里的持仓成本、当日盈亏；
- 某个 App 里的分时/Level-2 画面、公告原文。

它和「股票分析」工具是**互补**关系，不是替代：K 线、缠论、行情该走接口还是走接口（快、稳、可复现），
只有接口拿不到的东西才值得"开 App 看一眼"。

## 1. 组成

| 层 | 文件 | 职责 |
|---|---|---|
| 无障碍服务 | `android/.../miniphone/MiniPhoneAccessibility.kt` | 读无障碍树、下发手势、全局按键、主屏截图 |
| MethodChannel 桥 | `android/.../miniphone/MiniPhoneBridge.kt` | Flutter ↔ 原生，所有调用返回 `Map` |
| Dart 通道 | `lib/tools/mini_phone_channel.dart` | 类型化封装 + `renderScreenForModel` 文本化 |
| AI 工具 | `lib/tools/phone_tools.dart` | 7 个 `AppTool`，挂到 `ChatController._collectTools()` |
| 开关 | `Assistant.enablePhoneControl` | 助手编辑页「能力 → 手机操控」 |

## 2. 工具

| 工具 | 参数 | 说明 |
|---|---|---|
| `mini_phone_observe` | `resourceIds?` `maxElements?` | 读屏，返回元素表（ref / role / 名字 / 坐标 / 可点可输入） |
| `mini_phone_find` | `text` | 在当前屏按文字找元素，省 token（长列表、聊天记录） |
| `mini_phone_tap` | `ref` 或 `x,y`，`long?` | 点击；ref 失效时退回坐标 |
| `mini_phone_type` | `ref` `text` `clear?` | 写输入框（`ACTION_SET_TEXT`，不依赖输入法） |
| `mini_phone_scroll` | `direction` `amount?` 或 `x1,y1,x2,y2` | 滚动/滑动 |
| `mini_phone_press` | `key`=back/home/recents | 系统键 |
| `mini_phone_open` | `package` 或 `url` | 打开 App / 用某 App 打开链接 |

**所有写动作都会自动再读一次屏**并把结果一起返回，模型不用多花一轮确认。

## 3. 关键设计

1. **ref 只在一次读屏内有效。** 每次 `observe` 重新编号（`@e1`、`@e2`…按遍历顺序）。
   跨轮次点击时，`clickRef` 会按 ref 重拍一次屏拿到中心坐标，再用坐标回查节点，
   所以**ref 过期不会点错位置**，最坏是返回 `ok:false`。
2. **先找可点击祖先。** 行情 App 大量用自定义 View，文字节点本身不可点；
   点击时向上找最近的 `isClickable` 祖先，找不到才按坐标点。
3. **点击时长 90ms。** 太短的 down-up 会被判成滑动而丢掉，这是实测踩过的坑。
4. **输入走 `ACTION_SET_TEXT`，不用模拟键盘。** 稳、快，也不会把系统输入法切来切去；
   代价是某些自绘输入框（少见）不响应，那时用 `mini_phone_tap` 聚焦后由用户手动补。
5. **不缓存屏幕。** 用户随时可能在动手机，任何"上一秒的画面"都不值得相信。
6. **原生不依赖 kotlinx.coroutines。** 所有原生方法都是同步"下发即返回"，
   便于单独用 kotlinc + android.jar 做语法校验（见下）。

## 4. 与 Mika 的关系

参考过 `wangzan101/Mika`（Apache-2.0）的方案，但**没有移植它的运行时**：

| Mika 的做法 | 我们的做法 | 原因 |
|---|---|---|
| 建虚拟屏（`createVirtualDisplay`）后台操作，不占用户屏幕 | 直接操作主屏 | 建虚拟屏要 shell 级身份（无线调试 / Shizuku），门槛高、易被封 |
| 内置 shell 助手，走 ADB 配对 | 纯无障碍服务 | 无障碍只需用户点一下开关，Android 11+ 的安全边界也更清楚 |
| Kotlin 侧跑完整的 Agent 循环 | 模型循环留在 Flutter，Kotlin 只提供原子动作 | 避免两套 Agent 打架，工具和记忆都留在 Dart 侧 |

**代价**：操作的是用户正在看的屏幕，会打断用户；前台是本 App 时读不到别的内容。
要用的时候最好把 mew问股 切后台、让它自己开 App。

## 5. 开启步骤

1. 助手编辑页 → 工具 → 能力 → 打开「手机操控」（会顺手跳系统设置）。
2. 系统设置 → 无障碍 → **问股操控** → 打开。
3. 回到对话，让它"看一下同花顺的自选股"。

工具层在无障碍未开启时会返回 `accessibility_off` 并给出这一步，不会静默失败。

## 6. 边界与已知限制

- **只能读前台。** 后台 App 读不到（无障碍就是这样）。
- **会占用屏幕。** 模型在操作时用户会看到界面在动，这是主屏方案的必然代价。
- **截图仅安卓 11+**，且部分 App（银行、支付）禁止截屏，此时只能靠无障碍树。
- **不碰支付/登录验证码。** 这类页面交给用户本人，工具不做自动填。
- **不猜数据。** 读不到就说读不到，不允许把"看不见"编成"没有"。

## 7. 校验方式

本机没有 Flutter SDK（arm64），所以：

- Dart 侧：`dart format --page-width 120`（已纳入 CI 的格式门禁）+ `flutter analyze`（CI）；
  `test/mini_phone_tools_test.dart` 覆盖渲染与开关序列化。
- Kotlin 侧：`kotlinc -classpath android.jar` 单独编译 `miniphone/` 三个文件（Flutter 桩放在
  `/workspace/kotlin-stub`，不进仓库）。

## 8. 下一步（P1）

- [ ] 截图回传：让模型真的"看"图形界面（现在只有无障碍树文本）
- [ ] 操作后等待界面稳定（现在固定"动作后立刻读"）
- [ ] 常用流程缓存成 skill（"同花顺看自选"点一次就会）
- [ ] 敏感页面识别（支付/密码框）直接转人工

## 9. 参考与致谢

设计阶段读了 `wangzan101/Mika`（Apache-2.0，"on-device AI agent for Android"）的实现来确认两件事：
Android 上"让 AI 操作 App"到底需要什么权限、以及各家怎么处理点击的可靠性（可点击祖先、
手势时长、自定义 View 的坐标兜底）。**没有复制它的代码**：本模块全程只依赖系统无障碍 API，
管线（Kotlin 原子动作 + Dart 模型循环）是自己写的，见第 4 节的取舍表。

它的 Apache-2.0 NOTICE 是 `Mika / Copyright 2026 wangzan101`；如果后续真的搬它的某个文件进来，
需要在本仓库 `NOTICE` 里补一条署名。
