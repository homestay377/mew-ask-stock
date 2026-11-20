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
