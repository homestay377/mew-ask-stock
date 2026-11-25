# 对标 Mika：手机操控 / 虚拟屏 / 读屏

本文是**可维护的对标基线**，不是感想。项目参考实现：Mika（Apache-2.0），
**基线提交 `a40f6a9`**（2026-11-24 核对）。Mika 之后新增的功能，按本文第 5 节的流程逐条评估。

我们的实现都在 `android/app/src/main/kotlin/io/github/homestay377/mewaskstock/shell/` 与
`lib/tools/virtual_display_*.dart`；读屏在 `miniphone/`、`ocr/`。

---

## 1. 两边到底差在哪：架构层面

Mika 的路子是「**一个 shell 进程 + 一个富接口**」：`IMikaShell.aidl` 有 62 个方法，
建屏、启动、挪任务、注入、保活、剪贴板、静音、多用户全在里面，App 侧只做编排。

我们是「**一个 shell 进程 + 一个瘦接口**」：`IShellDisplay.aidl` 9 个方法
（建屏 / 释放 / 启动 / 顶层任务 / 点 / 滑 / 键 / 身份 / 错误），其余编排在 Dart。

这不是缺点：瘦接口更安全（不碰剪贴板、账号、多用户），但也确实少了几件**让体验顺滑**的能力。
差距按"该不该补"排在第 3 节。

## 2. 逐项对照（现状 = 我们有没有）

| 能力 | Mika 的做法（文件:函数） | 现状 | 备注 |
|---|---|---|---|
| 建屏标志位 | `ShellService.displayFlags(sdk, trusted)`：PUBLIC\|OWN_CONTENT_ONLY\|SUPPORTS_TOUCH\|ROTATES_WITH_CONTENT\|DESTROY_CONTENT_ON_REMOVAL，13+ 加 TOUCH_FEEDBACK_DISABLED，可信时加 TRUSTED\|OWN_DISPLAY_GROUP\|ALWAYS_UNLOCKED，14+ 加 OWN_FOCUS\|STEAL_TOP_FOCUS_DISABLED | ✅ 一致 | `ShellDisplayService.displayFlags` |
| 可信降级 | `retryWithoutTrust(t) = t is SecurityException`，只降一次 | ✅ 更宽 | 我们多给 trusted/untrusted/minimal/bare 四档 |
| owner 包名 | 反射 7 参 `createVirtualDisplay(..., packageName)`，且上下文归属必须是 shell | ✅ 一致 | `ShellContext` 重写了 getPackageName/getOpPackageName/getAttributionSource |
| 全屏窗口模式 | `setFullscreenWindowingMode`：IWindowManager.setWindowingMode(id,1)，失败退 `wm set-display-windowing-mode` | ✅ 一致 | freeform 会让 App 缩成小窗、坐标偏 |
| 输入法策略 | `setDisplayImePolicy(id, 0)`（LOCAL） | ✅ 一致 | 让输入法弹在虚拟屏而不是主屏 |
| **屏保活** | `DisplayAwake`：4s 一次反射 `IPowerManager.userActivity(displayId, now, EVENT_TOUCH=2, 0)`；**只在屏真的自成一组时**才报 | ✅ **本轮补上** | 缺它 = 到息屏时间画面不合成、截图不变、点了没反应 |
| 画面接收 | `AgentDisplay`：ImageReader + HandlerThread，≤10 帧/秒，行填充按 rowStride/pixelStride 处理 | ✅ 一致 | `VirtualDisplayHost` |
| 本地 skeleton 屏 | **没有这一步** | ✅ **本轮删掉** | 我们原来多建一块本地屏抢同一 Surface，会互相清帧 |
| 启动到指定屏 | `startActivityAsUser` 12 参反射 + `setLaunchDisplayId`，失败退 `am start --display` | ✅ 一致 | |
| 启动返回值语义 | 0/1/2/3/4/5/6/7/8（含"用户正在主屏用"、"另一块屏在用"、"冷启动被降级"） | 🟡 部分 | 我们只有 0/1/2/3 共用同一套码值 |
| 挪任务回屏 | `moveTask(taskId, displayId)`：`moveRootTaskToDisplay`，失败退 `am display move-stack` | ❌ 缺 | App 从后台拉起别的 App 时会落到主屏，Mika 靠这个挪回来 |
| 发现任务掉到主屏 | `watchMainScreen(windowMs)` + `mainArrivals(since)` + `MainScreenSpill.decide`（6 秒窗口，排除用户自己点的） | ❌ 缺 | 这是"我在虚拟屏点的，怎么跑到用户眼前了"的根治手段 |
| 读屏（树） | `AccessibilityService.windowsOnAllDisplays[displayId]`，剔除输入法/浮层，深度 80、去重、**坐标归一化 0..999** | ✅ 基本一致 | `MiniPhoneAccessibility.snapshot(displayId)` |
| **无障碍自己开** | `RecoveryPermissions`：shell 身份 `settings put secure enabled_accessibility_services`（先读后合并、两种组件名写法、回读校验） | ✅ **本轮补上** | `AccessibilityEnabler` + `IShellDisplay.execShell`；用户不再需要去系统设置里点 |
| 界面指纹 | FNV-1a 混 className/text/desc/bounds/states（**界面结构**指纹） | 🟡 部分 | 我们有**帧像素**指纹（64×64 采样）判断"变没变"；缺结构指纹，无法做"同一页不重复读" |
| 读屏（OCR） | 中文 + 拉丁**两套模型并行**，坐标同样归一化 | ✅ 一致 | `ScreenOcr` |
| 点击/滑动 | `injectInputEvent` + setDisplayId；按键用 WAIT_FOR_RESULT（派发失败要能察觉），触摸 ASYNC | ✅ 基本一致 | |
| 手势笔画 | `injectStroke(displayId, xs, ys, times)`：按时间逐点注入 | ❌ **缺（优先）** | 长按、拖动、精确滑动都靠它；我们只有等速 swipe |
| 输入文字 | 三条路：无障碍 ACTION_SET_TEXT / `injectAsciiText`（键盘事件）/ 剪贴板 + 粘贴 | 🟡 两条 | 有前两条；缺剪贴板路径——没连无障碍时打不了中文 |
| 滚轮 | `WheelDriver` 用 ACTION_SCROLL 而不是模拟手指 | ❌ 缺 | 长列表更稳，也避免把"滚动"识别成"拖拽" |
| 主屏不被抢 | `STEAL_TOP_FOCUS_DISABLED` + `MainScreenSpill` / `PipInput` | 🟡 只有前者 | |
| 状态诊断 | `ScreenDiagnosis.classify` + Advice 文案 | ❌ 缺 | 我们只有 lastError / describe() |
| **前台服务保活** | 内置助手常驻 + 通知 | ✅ **本轮补上** | `ChatGenerationService` hold/status/release，通知显示当前动作 |
| **悬浮图标** | `OverlayHost`（系统级悬浮窗） | 🟡 我们做在 App 内 | 系统级悬浮图标已加（`FloatingBadge`），需 `SYSTEM_ALERT_WINDOW`（用 shell appops 开） |
| **屏幕导航键** | 无（靠注入 BACK） | ✅ 我们多做了 | 放大视图下方一排 返回/桌面/最近任务 |

## 3. 该补的，按性价比排

**高**

1. **保活**（已完成）。缺它的症状和"功能没做"完全一样：屏在、App 在、就是不动。
2. ~~**输入文字的第二条路**~~（已完成）：`IShellDisplay.injectAsciiText` + `vd_type` 的 x/y/纯焦点三种给法。
3. **`moveTask`**。App 从后台拉起别的页面（同花顺的行情详情、雪球的外链）会落到主屏，
   用户手机突然跳屏。补一个 moveTask + 启动后校验 topTask 就够了，不必上 `watchMainScreen`。

**中**

4. 界面指纹（判断"换了没有"，省 token、避免重复读）。
5. `injectStroke`（长按/拖动）。
6. 启动返回值细分（尤其 `in_use_on_main`），Dart 侧据此给"你在主屏用着它，先退出来"。
7. WheelDriver 式的滚动。

**低 / 不做**

- 剪贴板接管、静音、多用户、通话音频、文件桥：这些是 Mika 替代用户操作才需要的，
  我们的定位是"看行情、点按钮"，碰用户账号和支付没有收益。
- `watchMainScreen` 的完整版：成本高，先靠 moveTask 兜。

## 3.5 工具默认开

Mika 的能力是"装好就有"。我们原来 `enableVirtualDisplay` 默认 `false`，模型连工具都看不到，
表现就是"AI 说它没有虚拟屏能力"。现在默认 `true`，并做了一次性迁移把老配置也打开
（写 `vdAutoOn` 标记，之后不再动；用户在助手设置里关掉仍然有效）。

## 4. 已知的、我们故意不跟的地方

- 接口瘦：不加 `setClipText` / `setAudioMuted` / `startAppInUser` 这类需要碰用户隐私的能力。
- 不做"替用户输入密码/验证码"。

## 5. 以后 Mika 更新了怎么办

```sh
cd /workspace/mika && git log --oneline a40f6a9..HEAD            # 只看基线之后的提交
git diff a40f6a9..HEAD -- app/src/main/java/com/wangzan101/mika/cap/phone \
   app/src/main/aidl core/src/main/kotlin/com/wangzan101/mika/core/device
```

逐条判断，按这个顺序过：

1. **改的是哪一层**：AIDL（要两边同步改）/ shell 进程 Kotlin / App 侧 Kotlin / Dart 工具层。
2. **是不是"缺了就像没做"的那类**（保活、权限、降级）——这类直接搬。
3. **是不是为了绕某个 ROM 的坑**（注释里通常写了机型/版本）——搬，并在我们代码里保留原注释出处。
4. **是不是为了隐私/账号能力**——跳过，记在第 4 节。
5. 搬完把基线提交号更新到本文开头，并在下面记录。

### 变更记录

| 日期 | Mika 基线 | 搬了什么 |
|---|---|---|
| 2026-11-24 | `a40f6a9` | 首版基线。补 `DisplayAwake` 保活、删本地 skeleton 屏、补 `injectAsciiText` 键盘注入、无障碍自动开启 |
| 2026-11-25 | `a40f6a9` | 继续：前台服务保活 + 系统级悬浮图标、帧像素指纹（判断"变没变"）、无进展检测（阈值可调）、导航键、回合上限可调 |