// 本地验证脚本（CI 不执行）。用 print 输出对照结果，允许相对路径导入 lib。
// ignore_for_file: avoid_print, unused_import, avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/stock/chanlun.dart';
import '../lib/stock/tdx_formula.dart';

void main(List<String> args) {
  final goldenPath = args.isNotEmpty ? args[0] : 'test/fixtures/chan/golden_300274.json';
  final formulaPath = args.length > 1 ? args[1] : 'test/fixtures/chan/chan_formula.txt';

  final golden = jsonDecode(File(goldenPath).readAsStringSync()) as Map<String, dynamic>;
  final formula = File(formulaPath).readAsStringSync();

  final barsRaw = golden['bars'] as List;
  final bars = <Bar>[
    for (final b in barsRaw)
      Bar(
        (b['o'] as num).toDouble(),
        (b['h'] as num).toDouble(),
        (b['l'] as num).toDouble(),
        (b['c'] as num).toDouble(),
        v: (b['v'] as num?)?.toDouble() ?? 0.0,
        t: b['dt'] as String? ?? '',
      ),
  ];

  final sw = Stopwatch()..start();
  final result = Chanlun.analyze(bars, formula);
  sw.stop();

  final goldenPens = golden['pens'] as List;
  final goldenBoxes = golden['boxes'] as List;
  final goldenSeries = (golden['series'] as Map).cast<String, dynamic>();

  var failures = 0;

  // ---- 笔 ----
  print('=== 笔 ===  golden=${goldenPens.length}  dart=${result.pens.length}');
  if (goldenPens.length != result.pens.length) {
    print('  ✗ 数量不符');
    failures++;
  } else {
    var penOk = true;
    for (var i = 0; i < goldenPens.length; i++) {
      final g = goldenPens[i];
      final d = result.pens[i];
      final idxOk = (g['idx'] as num).toInt() == d.idx;
      final priceOk = ((g['price'] as num).toDouble() - d.price).abs() < 1e-6;
      final typeOk = (g['type'] as String) == d.type;
      if (!idxOk || !priceOk || !typeOk) {
        print(
          '  ✗ pen[$i] golden=${g['idx']}/${g['price']}/${g['type']} '
          'dart=${d.idx}/${d.price}/${d.type}',
        );
        penOk = false;
        failures++;
      }
    }
    if (penOk) print('  ✓ 全部 ${goldenPens.length} 笔逐值一致（≤1e-6）');
  }

  // ---- 中枢 ----
  print('=== 中枢 ===  golden=${goldenBoxes.length}  dart=${result.boxes.length}');
  if (goldenBoxes.length != result.boxes.length) {
    print('  ✗ 数量不符');
    failures++;
  } else {
    var boxOk = true;
    for (var i = 0; i < goldenBoxes.length; i++) {
      final g = goldenBoxes[i];
      final d = result.boxes[i];
      final same =
          g['tag'] == d.tag &&
          (g['s'] as num).toInt() == d.s &&
          (g['e'] as num).toInt() == d.e &&
          ((g['zg'] as num).toDouble() - d.zg).abs() < 1e-6 &&
          ((g['zd'] as num).toDouble() - d.zd).abs() < 1e-6;
      if (!same) {
        print(
          '  ✗ box[$i] golden=${g['tag']}[${g['s']}-${g['e']}] ${g['zg']}/${g['zd']}  '
          'dart=${d.tag}[${d.s}-${d.e}] ${d.zg}/${d.zd}',
        );
        boxOk = false;
        failures++;
      }
    }
    if (boxOk) print('  ✓ 全部 ${goldenBoxes.length} 个中枢逐值一致');
  }

  // ---- 序列 ----
  print('=== 公式序列 ===');
  var seriesChecked = 0;
  var seriesOk = 0;
  goldenSeries.forEach((key, value) {
    final expected = (value as List).map((e) => (e as num).toDouble()).toList();
    final actual = result.data[key];
    seriesChecked++;
    if (actual == null) {
      print('  ✗ $key 缺失');
      failures++;
      return;
    }
    if (actual.length != expected.length) {
      print('  ✗ $key 长度 ${actual.length} != ${expected.length}');
      failures++;
      return;
    }
    var bad = 0;
    for (var i = 0; i < expected.length; i++) {
      final diff = (expected[i] - actual[i]).abs();
      if (diff > 1e-6) {
        if (bad < 3) {
          print('  ✗ $key[$i] expected=${expected[i]} actual=${actual[i]}');
        }
        bad++;
      }
    }
    if (bad == 0) {
      seriesOk++;
    } else {
      print('  ✗ $key: $bad/${expected.length} 个值不符');
      failures++;
    }
  });
  print('  $seriesOk/$seriesChecked 个序列逐值一致');

  // ---- 公式错误 ----
  print('=== 公式错误 ===  ${result.errors.length} 条');
  for (final e in result.errors) {
    print('  line ${e.line}: ${e.message}  [$e.text]');
  }

  // ---- 统计 ----
  print('=== 统计 ===');
  print(
    '  bars=${result.stats.bars} pens=${result.stats.pens} boxes=${result.stats.boxes} '
    'errors=${result.stats.errors} boxPosition=${result.stats.boxPosition}',
  );
  print('  耗时 ${sw.elapsedMilliseconds} ms');

  // ---- 背驰/买卖点（仅展示，golden 未固化） ----
  print('=== 背驰信号 ===  ${result.signals.length} 个');
  for (final s in result.signals) {
    print('  idx=${s.idx} ${s.label} @${s.price} strength=${s.strength}');
  }
  print('=== 买卖点 ===  ${result.points.length} 个');
  for (final p in result.points) {
    print('  idx=${p.idx} ${p.label} @${p.price}');
  }

  print('');
  if (failures == 0) {
    print('★★★ 全部通过 ★★★');
  } else {
    print('✗✗✗ 失败 $failures 项 ✗✗✗');
    exitCode = 1;
  }
}
