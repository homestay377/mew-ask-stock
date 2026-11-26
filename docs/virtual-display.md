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
| `vd_status` | 现在能不能用：Shizuku 跑没跑、授权没授权、屏建没建；`rebuild="true"` 强制重建（排障） |
| `vd_open` | 打开 App（**中文名或包名都行**，名字→包名由 PackageManager 解析）；`list="true"` 只列已装 App |
| `vd_observe` | 读那块的界面（元素 + ref + 坐标；没有无障碍时退到本机 OCR）；给 `text` 就只找匹配项 |
| `vd_tap` | 点：`ref` / `text`（自动在无障碍树和 OCR 里找）/ `x,y` 三种给法 |
| `vd_scroll` / `vd_type` / `vd_back` | 滚、输入（需 ref）、返回 |

写动作后**自动再读一次屏**，模型不用多花一轮确认。

### 自动建屏（不需要用户点「准备」）

任何 `vd_*` 工具入口都先走 `ensureReady()`：

1. 已经有屏 → 直接用（只读 `status()`，不额外调用）；
2. 没屏 → **静默** `ensure_display`；
3. 缺前提才报，而且只报那一步：
   - `need_permission` → 自动弹一次 Shizuku 授权框（每进程只弹一次），等 3 秒复查；
   - `not_running` → 自动打开 Shizuku，让用户点「启动服务」；
   - `not_installed` → 提示装 Shizuku 或走无线调试。

并发安全：建屏用 **单次 `Future` 锁**（`building`），同轮多个工具同时触发也只建一块屏。

原则：**用户已经给过权限之后，不许再让他手动准备**。

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
- **不连无障碍时只能读文字、不能输入**：OCR 给文字和坐标，能点不能打字（打字的输入框定位依赖无障碍树）。
- 支付、登录验证码不自动填，交给用户。
- Shizuku 服务重启会导致 binder 断开，需要重绑（工具会提示）。

## 8. 排查

1. `vd_status`：先确认 Shizuku 是 `ready`；
2. `vd_status(rebuild="true")`：确认 `display.phase == ready`；
3. 打开 App 后 `vd_observe` 若有 `displayId` 但没元素：可能 App 还没画完，等 1–2 秒重试；
4. 坐标全偏：检查 `setWindowingMode` 是否成功（少数系统会拒绝，退 `wm` 命令也在日志里）。

日志标签：`ShellDisplay`（shell 侧）、`ShizukuChannel`、`VirtualDisplayHost`、`VirtualDisplayMgr`。

## 9. B 路线：无线调试（已实现）

Shizuku 不是唯一通路。系统「开发者选项 → 无线调试」开着时，adbd 会在本机公布一个 TLS 端口；
**配对一次之后，我们就能在 adbd 上开 `exec:` 流，以 uid 2000 跑命令**。

流程：

```
用户：设置 → 开发者选项 → 无线调试 → 使用配对码配对设备（对话框别关）
     ↓ 抄 6 位码
App ：mDNS 找 _adb-tls-pairing._tcp 端口
     ↓ TLS 1.3（双方自签证书，互不校验证书链）
     ↓ 口令 = 配对码 + TLS 导出密钥("adb-label\0")
     ↓ SPAKE2 交换 → AES-GCM 互换 PeerInfo（我们发 adb 公钥）
配对成功（之后设备就认这把证书了）
     ↓ mDNS 找 _adb-tls-connect._tcp 端口
     ↓ 开 exec: 流 → CLASSPATH=<base.apk> app_process /system/bin ShellServiceMain <pkg>
助手进程起来，回环 socket 交回 IShellDisplay binder
```

### 为什么这么绕

- **不能直接 `am start-service`**：那会以 App 自己的 uid 运行，建不出虚拟屏。
- **不能把 binder 写进文件**：只能走回环 socket + 一次性口令（[ShellHelperHandoff]）。
- **端口每次都会变**：只能问 mDNS，写死没用。

### 三个必须逐字节对齐的实现细节

1. **SPAKE2 的口令标量**：`SHA-512(口令) mod L`，再按低三位依次加 L、2L、4L，使它成为 8 的倍数。
   这是设备端的历史行为，少一步就协商失败。
2. **AES-GCM 的 nonce**：12 字节，前 8 字节是**各自方向的序号**（小端，从 0 起每条加一），其余为零。
3. **PeerInfo 包**：6 字节头（版本 1 / 类型 / 大端长度）+ 8192 字节负载，第一字节是密钥类型（0=RSA）。

### 与 Shizuku 的关系

`ShellRouter` 按这个顺序选：**Shizuku 就绪 → 用 Shizuku；否则已配对无线调试 → 拉助手**。
两条路产出同一个 `IShellDisplay`，上层完全无感。任意一条挂了可以退到另一条。

### 已知限制

- 无线调试**重启手机后要重新开**（系统行为），但配对关系保留，重开之后点一次「启动助手」即可。
- 同一台机器上，Shizuku 和无线调试可以同时可用，路由只会选一个，不会两边都建屏。
- 「解除配对」会删掉本机私钥，下次需要重新抄配对码。
