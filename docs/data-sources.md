# 数据源实测结论（Dart / Android）

> 所有结论来自本机 Dart 3.13/3.14 实际请求，不是照搬 Eta（Kotlin）时期的笔记。
> 复现脚本：`tool/probe_sources.dart`、`tool/probe_sources2.dart`。

## 结论总表

| 用途 | 接口 | 状态 | 备注 |
|---|---|---|---|
| A 股日/周/月 K 线 | `ifzq.gtimg.cn/appstock/app/fqkline/get` | ✅ 可用 | **必须用 `ifzq` 域名**，`web.ifzq` 已被 WAF 拦成 501 |
| **备源**（腾讯挂时） | `money.finance.sina.com.cn/.../getKLineData` | ✅ 可用 | 不复权，除权日跳空；需 Referer |
| A 股分钟 K 线 | `ifzq.gtimg.cn/appstock/app/kline/mkline` | ✅ 可用 | **必须用 `ifzq.gtimg.cn`**；用 `web.ifzq.gtimg.cn` 会 302 到 `web3.ifzq.gtimg.cn` 并 10s 超时 |
| 境外指数/美股 K 线 | 同上（`usIXIC`/`usAAPL`） | ✅ 可用 | UTF-8 |
| A 股实时快照 | `qt.gtimg.cn/q=` | ⚠️ **GBK** | 必须 `gbk_bytes.decode` |
| A 股实时（备用） | `hq.sinajs.cn/list=` | ⚠️ **GBK** | 需带 `Referer: https://finance.sina.com.cn` |
| 伦敦金银 | `hq.sinajs.cn/list=hf_XAU` | ⚠️ **GBK** | 无成交量 |
| 东财 K 线 | `push2his.eastmoney.com/api/qt/stock/kline/get` | ✅ 可用 | 200，约 1.2s，比腾讯慢 |
| 东财实时 | `push2.eastmoney.com` | ❌ 超时 | 改域名 |
| 东财实时（可用） | `push2delay.eastmoney.com` | ✅ 可用 | 延迟行情，但字段完整 |
| 东财财报/龙虎榜 | `datacenter-web.eastmoney.com/api/data/v1/get` | ✅ 可用 | **不能带 `sortColumns=REPORT_DATE`**（该列不存在，报 9501） |

## 两个必须记住的坑

### 1. GBK 编码

新浪和腾讯的实时接口返回 **GBK 字节**，用 `utf8.decode` 会抛
`FormatException: Missing extension byte`。

正确写法：

```dart
import 'package:gbk_codec/gbk_codec.dart';

final bytes = await resp.fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d));
final text = gbk_bytes.decode(bytes.takeBytes());   // ✅
// 注意：gbk.decode(...) 走的是另一条路径，实测输出仍是乱码，不要用
```

验证：`[209,244,185,226,181,231,212,180]` → `阳光电源`。

### 2. 东财排序字段

```
❌ sortColumns=REPORT_DATE&sortTypes=-1   → {"success":false,"code":9501,"message":"REPORT_DATE排序列不存在"}
✅ 不传排序                                 → 正常返回，数据本身已按报告期倒序
```

## 取数长度

缠论要求**尽量给满历史**。实测 300274：

| 根数 | 笔 | 中枢 |
|---|---|---|
| 200 | 14 | 1 |
| 270 | 18 | 2 |
| 300 | 20 | 3 |
| 400 | 26 | 4 |
| 640 | 38 | 4 |

400 根起结果收敛。腾讯日线实际最多给约 640 根，所以固定取 640，用 `viewStart` 裁显示范围。

## ⚠ 腾讯 WAF 拦截（2026-11-20 实测）

`web.ifzq.gtimg.cn` 的 K 线接口现在返回 **HTTP 501**，并把请求重定向到
`waf.tencent.com/501page.html`。加 UA、Referer、Sec-Fetch 全套浏览器头都没用。

| 域名 | 结果 |
|---|---|
| `ifzq.gtimg.cn` | ✅ 200 正常 |
| `web.ifzq.gtimg.cn` | ❌ 501（WAF） |
| `web3.ifzq.gtimg.cn` | ❌ 连接超时 |
| `proxy.finance.qq.com` | ❌ 404 |

**结论：所有 K 线请求统一走 `ifzq.gtimg.cn`。**

因为这类外部依赖随时可能变，`StockSource.kline()` 改成双源：
腾讯为主（前复权），失败自动降级新浪（不复权）。
`KlineSeries.source` 会标明用了哪个源，面板上会提示「已切到新浪」。

## 新浪备源细节

```
https://money.finance.sina.com.cn/quotes_service/api/json_v2.php/
  CN_MarketData.getKLineData?symbol=sz300274&scale=240&ma=no&datalen=640
```

- 需要 `Referer: https://finance.sina.com.cn/`
- `scale`：日 240 / 周 1200 / 月 7200；分钟直接 5/15/30/60
- 返回 `[{day, open, high, low, close, volume}]`，字段名显式，不用猜
- **volume 单位是「股」**，腾讯是「手」，代码里除以 100 统一
- 范围：A 股、指数、ETF 都支持（实测 300274 / 000001 / 510300）
- **不复权**：除权日有跳空，缠论可能因此多出假信号

---

## 数据口径与质量（P4）

行情能不能算对，一半取决于「拿到的到底是什么数据」。以下约定写进代码，不靠人记。

### 1. 三级降级要留痕

`StockSource.kline()` 依次试 腾讯 → 新浪 → 东财，**降级成功也会记下主源的错误**：

- `KlineSeries.source`：`tencent` / `sina` / `eastmoney`
- `KlineSeries.fallbackReason`：主源/前置源报的错，主源成功时为 null
- `KlineSeries.provenance`：一句话串起来源、口径、收线时刻、拉取时间、降级原因

### 2. 复权口径必须跟着数据走

| 源 | 复权 | 备注 |
|---|---|---|
| 腾讯 `fqkline` | 前复权（qfq） | 主源 |
| 东财 `push2his` | 前复权（fqt=1） | 连接不稳，排第三 |
| 新浪 `getKLineData` | **不复权** | 除权日跳空，缠论会多假信号 |

`KlineSeries.adjust` 直接给出中文口径。**不同口径的序列不能拼成一条连续历史**，
跨周期对照时也要各自标注——`stock_levels` 每级都带 `source` / `adj`。

### 3. 时间语义

- 腾讯日/周/月：`2026-11-20`，代表**该交易日**，收盘时刻按 15:00 算
- 腾讯分钟：`202611201400`，12 位，是**这根 K 线的结束时刻**（10:30 = 9:30–10:30）
- 新浪：`2026-11-20` 或 `2026-11-20 15:00:00`
- 东财：`2026-11-20` 或 `2026-11-20 15:00`

`barClock(period, lastBar)` 输出 `closed` / `age` / `note`：最后一根收完没有、多久以前、
是否长时间没更新（≥4 天提示停牌或源滞后）。没有交易日历，所以**不区分节假日**，
宁可说「已收盘」也不假装实时。

### 4. 质量体检（`assessBars`）

只报明显毛病，阈值宁宽不严——假警报会让模型学会忽略警告：

| 检查 | 阈值 |
|---|---|
| 日期重复 | 与前一根 `t` 完全相同 |
| 日期倒序 | 解析后比前一根早 |
| 时间跳空 | 日 > 14 天 / 周 > 21 天 / 月 > 60 天；分钟线不查 |
| OHLC 不自洽 | `high < max(open,close)`、`low > min(open,close)`、`high < low`、非正数、NaN |
| 成交量 | 负数或非有限值算坏；**0 只上报不算错**（停牌） |
| 样本量 | < 30 根提示结构判断不可靠 |

### 5. 缓存不是实时数据

- `KlineSeries.fromCache` / `cacheAge`：内存/磁盘命中都会打标，`fetchedAt` **保留原始拉取时间**
- 磁盘缓存新增 `fetchedAt` 字段，老缓存没有则视为「拉取时间未知」
- `StockSource.lastRefreshError` + `klineCached(onRefreshFailed:)`：后台刷新失败不再静默
- 界面提示条按严重程度只显示一条：数据异常 > 已切备源 > 缓存陈旧/刷新失败
