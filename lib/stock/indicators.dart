/// 技术指标计算，口径逐值对齐 Eta 的 `assets/stock/indicators.js`。
///
/// 所有函数返回与输入等长的 `List<double?>`，前置不足周期处为 null。
/// 与 JS 版一致：MACD 首根为 0，KDJ 初值 50，RSI 用 Wilder 平滑。
library;

import 'dart:math' as math;

import 'chanlun.dart';

/// 简单移动平均。前 period-1 个为 null。
List<double?> sma(List<double> values, int period) {
  final n = values.length;
  final out = List<double?>.filled(n, null);
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    sum += values[i];
    if (i >= period) sum -= values[i - period];
    out[i] = i >= period - 1 ? sum / period : null;
  }
  return out;
}

/// 指数移动平均。首根取原值。
List<double?> ema(List<double> values, int period) {
  final n = values.length;
  final out = List<double?>.filled(n, null, growable: false);
  if (n == 0) return out;
  final k = 2 / (period + 1);
  var prev = values[0];
  out[0] = prev;
  for (var i = 1; i < n; i++) {
    prev = values[i] * k + prev * (1 - k);
    out[i] = prev;
  }
  return out;
}

/// 均线组，键为 `MA5` / `MA10` 等。
Map<String, List<double?>> maSeries(List<Bar> kl, List<int> periods) {
  final closes = kl.map((b) => b.c).toList();
  return {for (final p in periods) 'MA$p': sma(closes, p)};
}

/// 成交量均线，键为 `VMA5` 等。
Map<String, List<double?>> volMaSeries(List<Bar> kl, List<int> periods) {
  final vols = kl.map((b) => b.v).toList();
  return {for (final p in periods) 'VMA$p': sma(vols, p)};
}

/// MACD 结果。
class MacdResult {
  MacdResult(this.dif, this.dea, this.bar);

  final List<double?> dif;
  final List<double?> dea;
  final List<double?> bar;
}

/// MACD(12,26,9)。与 `indicators.js` 的 macd 完全一致：首根为 0。
MacdResult macd(List<Bar> kl, {int fast = 12, int slow = 26, int signal = 9}) {
  final closes = kl.map((b) => b.c).toList();
  final n = closes.length;
  final dif = List<double?>.filled(n, null, growable: false);
  final dea = List<double?>.filled(n, null, growable: false);
  final bar = List<double?>.filled(n, null, growable: false);
  if (n == 0) return MacdResult(dif, dea, bar);

  var e12 = closes[0];
  var e26 = closes[0];
  double deaPrev = 0;
  for (var i = 0; i < n; i++) {
    final c = closes[i];
    if (i == 0) {
      dif[0] = 0;
      dea[0] = 0;
      bar[0] = 0;
      continue;
    }
    e12 = c * (2 / (fast + 1)) + e12 * ((fast - 1) / (fast + 1));
    e26 = c * (2 / (slow + 1)) + e26 * ((slow - 1) / (slow + 1));
    final d = e12 - e26;
    deaPrev = d * (2 / (signal + 1)) + deaPrev * ((signal - 1) / (signal + 1));
    dif[i] = d;
    dea[i] = deaPrev;
    bar[i] = (d - deaPrev) * 2;
  }
  return MacdResult(dif, dea, bar);
}

/// 布林带结果。
class BollResult {
  BollResult(this.mid, this.up, this.low);

  final List<double?> mid;
  final List<double?> up;
  final List<double?> low;
}

/// BOLL(20,2)。
BollResult boll(List<Bar> kl, {int period = 20, double mult = 2}) {
  final closes = kl.map((b) => b.c).toList();
  final n = closes.length;
  final mid = List<double?>.filled(n, null, growable: false);
  final up = List<double?>.filled(n, null, growable: false);
  final low = List<double?>.filled(n, null, growable: false);
  for (var i = 0; i < n; i++) {
    if (i < period - 1) continue;
    var sum = 0.0;
    for (var j = i - period + 1; j <= i; j++) {
      sum += closes[j];
    }
    final m = sum / period;
    var varSum = 0.0;
    for (var j = i - period + 1; j <= i; j++) {
      varSum += math.pow(closes[j] - m, 2).toDouble();
    }
    final sd = math.sqrt(varSum / period);
    mid[i] = m;
    up[i] = m + mult * sd;
    low[i] = m - mult * sd;
  }
  return BollResult(mid, up, low);
}

/// KDJ 结果。
class KdjResult {
  KdjResult(this.k, this.d, this.j);

  final List<double?> k;
  final List<double?> d;
  final List<double?> j;
}

/// KDJ(9,3,3)。初值 K=D=50。
KdjResult kdj(List<Bar> kl, {int n9 = 9, int k3 = 3, int d3 = 3}) {
  final len = kl.length;
  final kOut = List<double?>.filled(len, null, growable: false);
  final dOut = List<double?>.filled(len, null, growable: false);
  final jOut = List<double?>.filled(len, null, growable: false);
  var prevK = 50.0;
  var prevD = 50.0;
  for (var i = 0; i < len; i++) {
    if (i < n9 - 1) continue;
    var hi = double.negativeInfinity;
    var lo = double.infinity;
    for (var j = i - n9 + 1; j <= i; j++) {
      if (kl[j].h > hi) hi = kl[j].h;
      if (kl[j].l < lo) lo = kl[j].l;
    }
    final rsv = hi == lo ? 50.0 : (kl[i].c - lo) / (hi - lo) * 100;
    prevK = (rsv + (k3 - 1) * prevK) / k3;
    prevD = (prevK + (d3 - 1) * prevD) / d3;
    kOut[i] = prevK;
    dOut[i] = prevD;
    jOut[i] = 3 * prevK - 2 * prevD;
  }
  return KdjResult(kOut, dOut, jOut);
}

/// RSI(period)，Wilder 平滑。
List<double?> rsi(List<Bar> kl, {int period = 14}) {
  final n = kl.length;
  final out = List<double?>.filled(n, null, growable: false);
  var avgGain = 0.0;
  var avgLoss = 0.0;
  for (var i = 0; i < n; i++) {
    if (i == 0) continue;
    final diff = kl[i].c - kl[i - 1].c;
    final gain = diff > 0 ? diff : 0.0;
    final loss = diff < 0 ? -diff : 0.0;
    if (i < period) {
      avgGain += gain;
      avgLoss += loss;
      if (i == period - 1) {
        avgGain /= period;
        avgLoss /= period;
        out[i] = avgLoss == 0 ? 100 : 100 - 100 / (1 + avgGain / avgLoss);
      }
    } else {
      avgGain = (avgGain * (period - 1) + gain) / period;
      avgLoss = (avgLoss * (period - 1) + loss) / period;
      out[i] = avgLoss == 0 ? 100 : 100 - 100 / (1 + avgGain / avgLoss);
    }
  }
  return out;
}

/// 指标参数说明。
///
/// 只记录「模型解释数值时会用到」的信息：参数、基于什么算、会不会重绘。
/// 不记录计算函数本身——那个在代码里，写在这里只会变成两份不一致的说明书。
class IndicatorSpec {
  const IndicatorSpec({
    required this.key,
    required this.label,
    required this.params,
    required this.basis,
    this.repaints = false,
  });

  /// 输出序列的键前缀，如 `MA` / `MACD`
  final String key;
  final String label;

  /// 参数，如 `5/10/20`
  final String params;

  /// 基于什么序列：`close` / `volume` / `high-low`
  final String basis;

  /// 是否可能随后续 K 线变化。
  ///
  /// 本项目所有指标都是纯价格序列计算，**全部 false**。
  /// 留着这个字段是为了以后有人加带未来函数的指标时有个明确的落点。
  final bool repaints;

  String get summary => '$label($params)';
}

/// 本项目实现的所有指标。
const List<IndicatorSpec> indicatorSpecs = [
  IndicatorSpec(key: 'MA', label: 'MA', params: '5/10/20', basis: 'close'),
  IndicatorSpec(key: 'BOLL', label: 'BOLL', params: '20, 2σ', basis: 'close'),
  IndicatorSpec(key: 'MACD', label: 'MACD', params: '12/26/9', basis: 'close'),
  IndicatorSpec(key: 'KDJ', label: 'KDJ', params: '9,3,3', basis: 'high-low-close'),
  IndicatorSpec(key: 'RSI', label: 'RSI', params: '14', basis: 'close'),
  IndicatorSpec(key: 'VOLMA', label: '量均', params: '5/10', basis: 'volume'),
];

/// 取若干指标的参数说明，压成一行。
String indicatorParamLine(Iterable<String> keys) {
  final want = keys.toSet();
  final parts = <String>[];
  for (final s in indicatorSpecs) {
    if (want.contains(s.key)) parts.add(s.summary);
  }
  return parts.join('，');
}
