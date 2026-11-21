<div align="center">

<h1>mew 问股</h1>

<p>基于 <a href="https://github.com/mizaawa/mewhub">MewHub</a> 的股票分析客户端，内置缠论引擎。</p>
<p>Flutter · Android / iOS · 本地计算 · 零云端</p>

</div>

---

## 这是什么

一份 MewHub 的分支，**在原版基础上增加了完整的 A 股技术分析与基本面能力**。

MewHub 原有的功能（多供应商 AI 对话、工具调用、MCP、世界书、记忆、多模态）**一行未改**，全部保留。改动只发生在新增目录里：

```
lib/stock/        纯数据与算法（不依赖 Flutter）
lib/ui/stock/     K 线面板与交互
lib/tools/        AI 工具（新增 8 个）
lib/data/         世界书种子与默认值
```

所以理论上可以把 `lib/stock/` 和 `lib/ui/stock/` 整体搬到任何 Flutter 项目里。

## 新增了什么

### 缠论引擎（Dart，从零实现）

| 文件 | 内容 |
|---|---|
| `lib/stock/tdx_formula.dart` | 通达信公式解释器（词法 / 语法 / 求值 / 序列函数），约 1050 行 |
| `lib/stock/chanlun.dart` | 笔、中枢、背驰、三类买卖点 |

**不是调库，是自己解析通达信公式后计算。** 这让「口径」完全可控。

验证标准（`tool/verify_golden.dart` 可复现）：

```
38 笔 / 4 中枢 / 16 条公式序列  逐值对齐参考实现（误差 ≤1e-6）
中枢 183.86-158.95、140.80-123.49 与通达信真机截图一致
```

### 行情数据层

```
lib/stock/stock_source.dart    三级降级：腾讯 → 新浪 → 东财
lib/stock/minute.dart          分时
lib/stock/stock_search.dart    搜索（A股 / ETF / 指数 / LOF）
lib/stock/stock_fundamental.dart  估值 / 财报 / 龙虎榜
```

三级降级不是设计癖好，是踩出来的：腾讯的 `web.ifzq` 域名曾被 WAF 拦成 501，整个面板刷不出图。

### K 线面板

`lib/ui/stock/stock_chart_panel.dart`（约 1800 行，自绘 Canvas）

- 周期：分时 / 日 / 周 / 月 / 60 / 30 / 15 / 5 分钟
- 主图指标：MA、BOLL、缠论中枢与笔、空心 K
- 副图指标：成交量、MACD、KDJ、RSI（**可多选**，一个不选只留主图）
- 手势：双指缩放、拖动平移、垂直缩放、长按 300ms 十字光标
- 搜索、自选分组（含分组管理）、AI 画线图层
- 离线缓存：冷启动先出图（约 30ms），再后台刷新

### AI 工具（8 个）

| 工具 | 作用 |
|---|---|
| `stock_kline` | 取 K 线，`period=minute` 时返回分时摘要 |
| `analyze_chan` | 缠论分析，返回可直接引用的中文结论 |
| `stock_quote` | 实时快照 |
| `stock_levels` | 多只 × 多周期并行对照 |
| `scan_stocks` | 批量扫描摘要，最多 20 只 |
| `get_fundamental` | 估值 + 财报 + 龙虎榜 |
| `chart_annotate` | 在图上画线，辅助解释正文 |
| `stock_panel_show` | 把面板切到指定标的，让用户看到你在分析什么 |
| `chart_context` | 读当前图表：标的、周期、数据源、选中那根 K 线及其指标值、缠论结构 |

**设计原则：让模型自己决定。** 项目早期试过从用户原话里用正则猜股票代码，实测「给我分析下平安银行」因为词表里只有「分析一下」而漏判。后来删掉整套路，改成模型主动调用 `stock_panel_show` —— 它已经知道答案，不需要猜。

### 世界书

`lib/data/stock_defaults.dart` —— 缠论口径 5 条 + 基本面口径 1 条。

**为什么用世界书而不是系统提示**：这些口径只在对应用户提到时才需要。塞进系统提示会全程占用上下文，且改动系统提示会让历史消息缓存全部失效。

## 关键技术决策

### 取数窗口必须够长

缠论依赖左侧历史（`BARSLAST` / `SUMBARS`），窗口太短会在左沿凭空造出中枢。实测 300274 日线：

| 根数 | 笔 | 中枢 |
|---|---|---|
| 200 | 14 | 1 |
| 270 | 18 | 2 |
| 300 | 20 | 3 |
| 400 | 26 | 4 |
| **640** | **38** | **4** |

400 根起收敛。所以固定取 640，必要时用 `viewStart` 只裁显示范围，不影响计算。

### 买卖点依赖「当前有效中枢」

判据是 `s <= signalIdx`（中枢已开始形成），**不是** `e <= signalIdx`。

因为中枢的右边界是**事后**才确定的，信号完全可能落在它形成过程中。早期用 `e` 判断会引用到几十根之前就结束、价格已经翻倍的中枢，结论看着成立但毫无实战价值。

另外加了距离约束：信号价离中枢边界超过 1.5 倍中枢高度时不再判定。

### 补零距离

- `jsonEncode(NaN)` 会抛 `JsonUnsupportedObjectError`，所有对外输出的数字统一走 `r2()`（`lib/stock/numbers.dart`）
- 原子写文件的 tmp 名必须唯一，否则并发写会互相覆盖
- 批量请求要限流（`mapLimit`），40 个并发容易被接口拦

## 构建

GitHub Actions 自动双端出包。

```bash
# 依赖
flutter pub get

# 本地构建（需 Flutter 3.47+ / Dart 3.13+）
flutter build apk --release
```

**注意**：Flutter 官方只提供 x64 Linux SDK。在 arm64 Linux 上无法本地构建，只能靠 CI。

格式化必须符合 `analysis_options.yaml` 的 `page_width: 120`：

```bash
dart format --page-width 120 lib test
```

## 仓库结构

```
lib/
├── ai/          供应商协议（OpenAI / Anthropic / Gemini）
├── chat/        对话控制、提示构建
├── core/        网络、路径、工具
├── data/        数据模型、设置、世界书
├── state/       全局状态
├── stock/       ★ 股票数据与算法（不依赖 Flutter）
├── tools/       ★ AI 工具（新增 8 个）
├── ui/
│   ├── chat/    对话界面
│   ├── pages/   设置页
│   └── stock/   ★ K 线面板、手势、搜索、自选
└── main.dart

docs/
├── data-sources.md   ★ 行情接口实测结论（含踩坑记录）
└── chan-kotlin.md    缠论口径说明

tool/
├── verify_golden.dart  ★ 缠论回归验证，可独立运行
└── probe_sources.dart  接口探测脚本
```

## 已知限制

1. **境外品种**（美股 / 指数 / 伦敦金）能取数做缠论，但**K 线面板只支持 A 股**
2. `get_fundamental` 不含研发投入、分红、股东结构、一致预期
3. 分时没有磁盘缓存（当天数据，隔天失效）
4. 舆情 / 情绪面未做
5. 缠论是 O(L²)，640 根约 30ms，但 2000 根以上需要优化

## 验证

```bash
# 缠论回归（无需 Flutter，纯 Dart）
dart run tool/verify_golden.dart
```

输出应包含 `★★★ 全部通过 ★★★` 与 38 笔 / 4 中枢 / 16 序列。

## 许可

本项目基于 [MewHub](https://github.com/mizaawa/mewhub)，沿用 **AGPL-3.0**。

原始 MewHub 的完整说明见下方。

<details>
<summary>原版 MewHub 说明（点击展开）</summary>

MewHub 是一个多供应商 AI 聊天客户端，功能参考 RikkaHub，用 Flutter 重写以同时支持 Android 与 iOS。界面是奶白色系，动画贯穿全程。

- 四种协议原生实现：OpenAI Chat Completions、OpenAI Responses、Anthropic Messages、Google Gemini，全部流式输出
- 任意第三方 API，多 Key 轮询，余额查询
- 深度思考六档，按厂商自动转换参数
- 工具调用（Agent 循环）：联网搜索、网页读取、长期记忆、计算器、时间、剪贴板、设备信息
- MCP：远程 Streamable HTTP 与 SSE
- 多模态：图片、拍照、PDF / Word / PPT / Excel / EPUB
- 世界书、模式注入、角色卡导入
- 后台会话、流式书写、分支与分叉

详见 [原仓库](https://github.com/mizaawa/mewhub)。

</details>