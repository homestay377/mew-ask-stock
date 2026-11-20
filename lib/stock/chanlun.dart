/// 缠论核心算法 —— Dart 移植版。
///
/// 口径对齐 Kotlin 版 `chan/Chanlun.kt`（后者已与 Python `chan_core.py` + `analyze.py`
/// 在 38 笔 / 4 中枢上逐值一致，误差 ≤1e-6）。
///
/// **最重要的结论（移植时原样保留）**：画线不准的根因不是公式算错，而是喂进来的窗口太短。
/// `BARSLAST / SUMBARS / BACKSET` 依赖左侧历史，窗口短了会在左沿凭空造中枢。
/// 实测 300274：只喂 270 根 → 3 个中枢（多出 `绿[1-46]` 伪框）；喂 641 根再裁到可视窗口 → 2 个，
/// 与通达信截图一致。所以调用方应当**尽量多取历史**，再用 [viewStart] 裁剪显示范围。
library;

import 'dart:typed_data';

import 'tdx_formula.dart';

/// 单根 K 线。
class Bar {
  Bar(this.o, this.h, this.l, this.c, {this.v = 0.0, this.t = ''});

  final double o;
  final double h;
  final double l;
  final double c;
  final double v;
  final String t;
}

/// 笔转折点。
class PenPoint {
  PenPoint({
    required this.idx,
    required this.price,
    required this.type,
    this.dir,
    this.from,
    this.to,
    this.fromPrice,
    this.toPrice,
    this.len,
    this.fromType,
    this.toType,
  });

  final int idx;
  final double price;

  /// `顶` / `底`
  final String type;

  // 下面这些字段由 [Chanlun.analyze] 回填，下游直接遍历 pens 读取。
  String? dir;
  int? from;
  int? to;
  double? fromPrice;
  double? toPrice;
  int? len;
  String? fromType;
  String? toType;
}

/// 中枢框。
class ChanBox {
  ChanBox({required this.tag, required this.s, required this.e, required this.zg, required this.zd, required this.mid});

  /// `红` / `绿`
  final String tag;
  final int s;
  final int e;

  /// 中枢上沿
  final double zg;

  /// 中枢下沿
  final double zd;
  final double mid;
}

/// 相邻笔连成的段。
class Bi {
  Bi({
    required this.from,
    required this.to,
    required this.fromPrice,
    required this.toPrice,
    required this.dir,
    required this.fromType,
    required this.toType,
    required this.len,
  });

  final int from;
  final int to;
  final double fromPrice;
  final double toPrice;

  /// `up` / `down`
  final String dir;
  final String fromType;
  final String toType;
  final int len;
}

/// 背驰信号。
class ChanSignal {
  ChanSignal({
    required this.idx,
    required this.type,
    required this.label,
    required this.level,
    required this.price,
    required this.strength,
  });

  final int idx;

  /// `buy` / `sell`
  final String type;
  final String label;

  /// `趋势` / `笔` / `极强`
  final String level;
  final double price;

  /// 力度衰减比，两位小数字符串
  final String strength;
}

/// 三类买卖点引用的中枢摘要（价格保留 2 位）。
class BoxRef {
  BoxRef(this.s, this.e, this.zg, this.zd);

  final int s;
  final int e;
  final double zg;
  final double zd;
}

/// 三类买卖点。
class ChanPoint {
  ChanPoint({
    required this.idx,
    required this.type,
    required this.label,
    required this.price,
    required this.reason,
    this.box,
  });

  final int idx;

  /// `buy` / `sell`
  final String type;

  /// `一买` / `二买` / `三买` / `一卖` / `二卖` / `三卖`
  final String label;
  final double price;
  final String reason;
  final BoxRef? box;
}

/// 统计摘要。
class ChanStats {
  ChanStats({
    required this.bars,
    required this.pens,
    required this.boxes,
    required this.errors,
    this.lastPen,
    this.lastBox,
    this.boxPosition,
  });

  final int bars;
  final int pens;
  final int boxes;
  final int errors;
  final PenPoint? lastPen;
  final ChanBox? lastBox;

  /// 现价相对最后一个中枢：`中枢上方` / `中枢下方` / `中枢内`。
  final String? boxPosition;
}

/// 缠论分析结果。
class ChanResult {
  ChanResult({
    required this.pens,
    required this.boxes,
    required this.bi,
    required this.stats,
    required this.signals,
    required this.points,
    required this.data,
    required this.errors,
    required this.bars,
  });

  final List<PenPoint> pens;
  final List<ChanBox> boxes;
  final List<Bi> bi;
  final ChanStats stats;
  final List<ChanSignal> signals;
  final List<ChanPoint> points;

  /// 公式产出的全部序列（已清洗）。
  final Map<String, Float64List> data;
  final List<FormulaError> errors;
  final List<Bar> bars;
}

/// 零面积守卫：低于此视为该段无同向动能。
const double _epsArea = 1e-6;

/// 面积缩到前段 85% 以下才算力度衰竭。
const double _divRatio = 0.85;

String _fmt2(double v) => v.toStringAsFixed(2);

/// 从 s 起、值保持不变的连续段终点。
int _runEnd(Float64List v, int s) {
  final base = v[s];
  var e = s;
  while (e + 1 < v.length && v[e + 1] == base) {
    e++;
  }
  return e;
}

class Chanlun {
  /// 红/绿两族常对同一段给出同一个中枢：时间+价格都重叠就合并，留跨度长的那个。
  /// 不合并会画出两个几乎重合的框。
  static List<ChanBox> mergeBoxes(List<ChanBox> boxes) {
    final bs = [...boxes]..sort((x, y) {
        if (x.s != y.s) return x.s - y.s;
        return (y.e - y.s) - (x.e - x.s);
      });
    final out = <ChanBox>[];
    for (final b in bs) {
      var hit = -1;
      for (var j = 0; j < out.length; j++) {
        final u = out[j];
        if ((u.e < b.e ? u.e : b.e) - (u.s > b.s ? u.s : b.s) <= 0) continue;
        final ov = (u.zg < b.zg ? u.zg : b.zg) - (u.zd > b.zd ? u.zd : b.zd);
        final span = (u.zg - u.zd) < (b.zg - b.zd) ? (u.zg - u.zd) : (b.zg - b.zd);
        if (span > 0 && ov > 0.6 * span) {
          hit = j;
          break;
        }
      }
      if (hit < 0) {
        out.add(b);
      } else if ((b.e - b.s) > (out[hit].e - out[hit].s)) {
        out[hit] = b;
      }
    }
    out.sort((a, b) => a.s - b.s);
    return out;
  }

  /// 按通达信规则算每个中枢框的 [起点, 终点]。
  ///
  /// 右边界 = min(顶值不变终点, 下一同类起点-1, 断点-1, 该族轨上线延伸段末根)
  static List<ChanBox> boxSpans(Map<String, Float64List> d, int s0) {
    final res = <ChanBox>[];
    for (final tag in ['红', '绿']) {
      final startSeq = d['${tag}起'];
      final topSeq = d['${tag}顶_锁定'];
      final botSeq = d['${tag}底_锁定'];
      final midSeq = d['${tag}中_锁定'];
      if (startSeq == null || topSeq == null || botSeq == null) continue;

      final starts = <int>[];
      for (var i = 0; i < startSeq.length; i++) {
        if (startSeq[i] > 0) starts.add(i);
      }

      final brkSeq = d['${tag}断点'];
      final brk = <int>[];
      if (brkSeq != null) {
        for (var i = 0; i < brkSeq.length; i++) {
          if (brkSeq[i] > 0) brk.add(i);
        }
      }

      final trackSeq = d['${tag}轨上线'];
      final ok = <int>[];
      if (trackSeq != null) {
        for (var i = 0; i < trackSeq.length; i++) {
          if (trackSeq[i].isFinite && trackSeq[i] > 0) ok.add(i);
        }
      }

      for (var index = 0; index < starts.length; index++) {
        final s = starts[index];
        if (s < s0) continue;
        var end = _runEnd(topSeq, s);
        if (index + 1 < starts.length) {
          final nextStart = starts[index + 1] - 1;
          if (nextStart < end) end = nextStart;
        }
        for (final bv in brk) {
          if (bv >= s) {
            if (bv - 1 < end) end = bv - 1;
            break;
          }
        }
        var lastOk = -1;
        for (final ov in ok) {
          if (ov >= s) lastOk = ov;
        }
        if (lastOk >= 0 && lastOk < end) end = lastOk;

        final zg = topSeq[s];
        final zd = botSeq[s];
        res.add(ChanBox(
          tag: tag,
          s: s,
          e: end,
          zg: zg,
          zd: zd,
          mid: midSeq != null ? midSeq[s] : (zg + zd) / 2,
        ));
      }
    }
    return res;
  }

  /// 主级笔转折点：X_70>0 取底，X_71>0 取顶，按索引排序。
  static List<PenPoint> penPoints(Map<String, Float64List> d, int s0, int n) {
    final pts = <PenPoint>[];
    final a70 = d['X_70'];
    final a71 = d['X_71'];
    for (var i = s0; i < n; i++) {
      if (a70 != null && a70[i] > 0) pts.add(PenPoint(idx: i - s0, price: a70[i], type: '底'));
      if (a71 != null && a71[i] > 0) pts.add(PenPoint(idx: i - s0, price: a71[i], type: '顶'));
    }
    pts.sort((a, b) => a.idx - b.idx);
    return pts;
  }

  /// 同向连续转折点只保留更极端的一个，保证顶底交替。
  static List<PenPoint> cleanPens(List<PenPoint> pts) {
    final out = <PenPoint>[];
    for (final p in pts) {
      final last = out.isEmpty ? null : out.last;
      if (last != null && last.type == p.type) {
        if (p.type == '顶') {
          if (p.price >= last.price) out[out.length - 1] = p;
        } else {
          if (p.price <= last.price) out[out.length - 1] = p;
        }
      } else {
        out.add(p);
      }
    }
    return out;
  }

  /// 公式没直接给 DIF 时用收盘价算 MACD 的 DIF（口径同参考实现）。
  static Float64List _difFromClose(List<Bar> b, int n) {
    final arr = Float64List(n);
    var e12 = b[0].c;
    var e26 = b[0].c;
    for (var q = 1; q < n; q++) {
      final cq = b[q].c;
      e12 = cq * (2.0 / 13.0) + e12 * (11.0 / 13.0);
      e26 = cq * (2.0 / 27.0) + e26 * (25.0 / 27.0);
      arr[q] = e12 - e26;
    }
    return arr;
  }

  static Float64List _deaFromDif(Float64List dif, int n) {
    final arr = Float64List(n);
    for (var i = 1; i < n; i++) {
      arr[i] = dif[i] * (2.0 / 10.0) + arr[i - 1] * (8.0 / 10.0);
    }
    return arr;
  }

  /// 主流程：给定 K 线，算出笔、中枢、背驰与三类买卖点。
  ///
  /// [bars] 时间正序。**必须喂全部可用历史**，不要只喂可视窗口。
  /// [load] 只用最后 N 根算（0 = 全部；除对账外不要用）。
  /// [viewStart] 可视窗口起点。计算仍在全历史上做，只把「完全落在窗口左侧」的中枢丢掉。
  static ChanResult analyze(
    List<Bar> bars,
    String formulaText, {
    int load = 0,
    int viewStart = 0,
  }) {
    final b = (load > 0 && bars.length > load) ? bars.sublist(bars.length - load) : bars;
    final n = b.length;
    if (n == 0) {
      return ChanResult(
        pens: const [],
        boxes: const [],
        bi: const [],
        stats: ChanStats(bars: 0, pens: 0, boxes: 0, errors: 0),
        signals: const [],
        points: const [],
        data: const {},
        errors: const [],
        bars: const [],
      );
    }

    final ohlcv = <String, Float64List>{
      'o': Float64List.fromList([for (final x in b) x.o]),
      'h': Float64List.fromList([for (final x in b) x.h]),
      'l': Float64List.fromList([for (final x in b) x.l]),
      'c': Float64List.fromList([for (final x in b) x.c]),
      'v': Float64List.fromList([for (final x in b) x.v]),
    };
    final res = runFormula(formulaText, ohlcv);
    final d = res.data;

    const s0 = 0;
    final pens = cleanPens(penPoints(d, s0, n));
    // ★ 先在全历史上合并（去重口径依赖完整序列），再只丢掉整体落在可视窗口左侧的框。
    var boxes = mergeBoxes(boxSpans(d, s0));
    if (viewStart > 0) {
      boxes = boxes.where((x) => x.e >= viewStart).toList();
    }

    // 笔连线；★ 这些字段必须回填到 pens 本身，下游直接遍历 pens 读
    final bi = <Bi>[];
    for (var p = 0; p < pens.length - 1; p++) {
      final a = pens[p];
      final c = pens[p + 1];
      final seg = Bi(
        from: a.idx,
        to: c.idx,
        fromPrice: a.price,
        toPrice: c.price,
        dir: c.price > a.price ? 'up' : 'down',
        fromType: a.type,
        toType: c.type,
        len: c.idx - a.idx,
      );
      bi.add(seg);
      a.dir = seg.dir;
      a.from = seg.from;
      a.to = seg.to;
      a.fromPrice = seg.fromPrice;
      a.toPrice = seg.toPrice;
      a.len = seg.len;
      a.fromType = seg.fromType;
      a.toType = seg.toType;
    }

    // ---- 背驰：同向两段的 MACD 力度对比 ----
    final dif = d['DIF'] ?? _difFromClose(b, n);
    final dea = d['DEA'] ?? _deaFromDif(dif, n);
    final hist = Float64List(n);
    for (var i = 0; i < n; i++) {
      hist[i] = (dif[i] - dea[i]) * 2;
    }

    double segArea(int a, int z, bool up) {
      var sum = 0.0;
      var i = a < 0 ? 0 : a;
      while (i <= z && i < hist.length) {
        final h = hist[i];
        if (h.isFinite) {
          if (up) {
            if (h > 0) sum += h;
          } else if (h < 0) {
            sum += -h;
          }
        }
        i++;
      }
      return sum;
    }

    final signals = <ChanSignal>[];
    for (var k = 2; k < bi.length; k++) {
      final cur = bi[k];
      final prev = bi[k - 2];
      if (cur.dir != prev.dir) continue;
      final up = cur.dir == 'up';
      // 必须创新极值：趋势背驰的定义是「新高/新低但力度不足」
      final createsExtreme = up ? cur.toPrice > prev.toPrice : cur.toPrice < prev.toPrice;
      if (!createsExtreme) continue;
      final a1 = segArea(prev.from, prev.to, up);
      final a2 = segArea(cur.from, cur.to, up);
      if (a1 <= _epsArea) continue;
      final lv = boxes.length >= 2 ? '趋势' : '笔';
      if (a2 <= _epsArea) {
        // 分子归零 = 这一段完全没出现同向柱，价格却创新极值 → 极强背驰
        signals.add(ChanSignal(
          idx: cur.to,
          type: up ? 'sell' : 'buy',
          label: '${up ? '顶' : '底'}背驰(极强)',
          level: '极强',
          price: cur.toPrice,
          strength: '1.00',
        ));
        continue;
      }
      if (a2 < a1 * _divRatio) {
        signals.add(ChanSignal(
          idx: cur.to,
          type: up ? 'sell' : 'buy',
          label: '${up ? '顶' : '底'}背驰($lv)',
          level: lv,
          price: cur.toPrice,
          strength: _fmt2(1 - a2 / a1),
        ));
      }
    }

    // ---- 三类买卖点（缠论定义，不是「背驰」的同义词）----
    //   一买：下跌趋势中，最后一个中枢**下方**出现底背驰，且随后的反弹回到中枢区间内
    //   二买：一买之后第一次回调，低点**不破**一买的低点
    //   三买：价格在最后一个中枢**上方**，回调的低点不跌回 ZG
    //   卖点对称
    final points = <ChanPoint>[];

    void pushPoint(int idx, String kind, double price, String why, ChanBox? box) {
      points.add(ChanPoint(
        idx: idx,
        type: kind.contains('买') ? 'buy' : 'sell',
        label: kind,
        price: price,
        reason: why,
        box: box == null
            ? null
            : BoxRef(box.s, box.e, double.parse(_fmt2(box.zg)), double.parse(_fmt2(box.zd))),
      ));
    }

    for (final sg in signals) {
      ChanBox? lastBoxAt;
      for (final bx in boxes) {
        if (bx.e <= sg.idx) lastBoxAt = bx;
      }

      if (sg.type == 'buy' && lastBoxAt != null && sg.price < lastBoxAt.zd) {
        // 一买：中枢下方的底背驰
        pushPoint(
          sg.idx,
          '一买',
          sg.price,
          '下跌笔在中枢下方底背驰，力度衰减 ${sg.strength}（中枢 ZD=${_fmt2(lastBoxAt.zd)}）',
          lastBoxAt,
        );

        // 二买：一买之后的下一次回调低点不破一买低点
        final afterIdx = sg.idx;
        final firstLow = sg.price;
        for (final seg2 in bi) {
          if (seg2.from < afterIdx) continue;
          if (seg2.dir == 'down' && seg2.toPrice > firstLow) {
            pushPoint(
              seg2.to,
              '二买',
              seg2.toPrice,
              '回调低点 ${_fmt2(seg2.toPrice)} 未破一买低点 ${_fmt2(firstLow)}',
              lastBoxAt,
            );
            break;
          }
          if (seg2.dir == 'down' && seg2.toPrice <= firstLow) break; // 破了就不是二买
        }
      }

      // 三买：价格在最后一个中枢上方，回调不跌回 ZG
      if (sg.type == 'buy' && lastBoxAt != null && sg.price > lastBoxAt.zg) {
        pushPoint(
          sg.idx,
          '三买',
          sg.price,
          '中枢上方回抽不破 ZG=${_fmt2(lastBoxAt.zg)}，底背驰力度 ${sg.strength}',
          lastBoxAt,
        );
      }

      if (sg.type == 'sell' && lastBoxAt != null && sg.price > lastBoxAt.zg) {
        pushPoint(
          sg.idx,
          '一卖',
          sg.price,
          '上涨笔在中枢上方顶背驰，力度衰减 ${sg.strength}（中枢 ZG=${_fmt2(lastBoxAt.zg)}）',
          lastBoxAt,
        );

        final afterIdx2 = sg.idx;
        final firstHigh = sg.price;
        for (final seg3 in bi) {
          if (seg3.from < afterIdx2) continue;
          if (seg3.dir == 'up' && seg3.toPrice < firstHigh) {
            pushPoint(
              seg3.to,
              '二卖',
              seg3.toPrice,
              '反弹高点 ${_fmt2(seg3.toPrice)} 未破一卖高点 ${_fmt2(firstHigh)}',
              lastBoxAt,
            );
            break;
          }
          if (seg3.dir == 'up' && seg3.toPrice >= firstHigh) break;
        }
      }

      if (sg.type == 'sell' && lastBoxAt != null && sg.price < lastBoxAt.zd) {
        pushPoint(
          sg.idx,
          '三卖',
          sg.price,
          '中枢下方反抽不上 ZD=${_fmt2(lastBoxAt.zd)}，顶背驰力度 ${sg.strength}',
          lastBoxAt,
        );
      }
    }

    // 按时间排序、去重（同 idx 同 label 只留一个）
    final seen = <String>{};
    final deduped = points.where((p) => seen.add('${p.idx}|${p.label}')).toList()
      ..sort((a, b) => a.idx - b.idx);

    final lastBox = boxes.isEmpty ? null : boxes.last;
    String? boxPosition;
    if (lastBox != null) {
      final cur = b[n - 1].c;
      if (cur > lastBox.zg) {
        boxPosition = '中枢上方';
      } else if (cur < lastBox.zd) {
        boxPosition = '中枢下方';
      } else {
        boxPosition = '中枢内';
      }
    }

    return ChanResult(
      pens: pens,
      boxes: boxes,
      bi: bi,
      stats: ChanStats(
        bars: n,
        pens: pens.length,
        boxes: boxes.length,
        errors: res.errors.length,
        lastPen: pens.isEmpty ? null : pens.last,
        lastBox: lastBox,
        boxPosition: boxPosition,
      ),
      signals: signals,
      points: deduped,
      data: d,
      errors: res.errors,
      bars: b,
    );
  }
}
