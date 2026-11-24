// 本机快速自检：`dart run tool/mini_phone_render_check.dart`
//
// 本机是 arm64，装不了 Flutter 官方 SDK，`flutter test` 跑不起来。这里只测与 Flutter 无关的纯函数，
// 用 dart 跑一遍就行；CI 里由 `test/mini_phone_tools_test.dart` 做正式门禁（两边用例保持一致）。

import 'dart:io';

int _failures = 0;

void check(String what, bool ok, [String? detail]) {
  if (ok) {
    stdout.writeln('  ok   $what');
  } else {
    _failures++;
    stdout.writeln('  FAIL $what${detail == null ? '' : '\n       $detail'}');
  }
}

/// 与 `lib/tools/mini_phone_channel.dart` 里的实现逐行一致（那边依赖 Flutter，无法在本机 import）。
String render(Map<Object?, Object?> screen, {int maxElements = 80}) {
  final s = <String, dynamic>{};
  screen.forEach((k, v) => s['$k'] = v);
  if (s['ok'] != true) {
    return '读屏失败：${s['error'] ?? 'unknown'}${s['message'] == null ? '' : '（${s['message']}）'}';
  }
  final pkg = s['package']?.toString();
  final size = (s['size'] as List?)?.join('×') ?? '?';
  final raw = (s['elements'] as List?) ?? const [];
  final buf = StringBuffer('屏幕：${pkg ?? '未知 App'}（$size），共 ${raw.length} 个元素');
  if (raw.length > maxElements) buf.write('，只列前 $maxElements 个');
  buf.writeln();
  var shown = 0;
  String? lastLine;
  for (final e in raw) {
    if (shown >= maxElements) break;
    final m = (e as Map).cast<String, dynamic>();
    final name = (m['name'] ?? '').toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    final role = (m['role'] ?? '').toString();
    final flags = <String>[
      if (m['clickable'] == true) '可点',
      if (m['editable'] == true) '可输入',
      if (m['scrollable'] == true) '可滚动',
      if (m['checked'] == true) '已选中',
      if (m['enabled'] == false) '不可用',
    ];
    final center = (m['center'] as List?) ?? const [0, 0];
    final line = '${m['ref']} $role「$name」@${center[0]},${center[1]}${flags.isEmpty ? '' : ' [${flags.join(' ')}]'}';
    final key = '$role|$name|${center[0]},${center[1]}';
    if (key == lastLine) continue;
    buf.writeln(line);
    lastLine = key;
    shown++;
  }
  return buf.toString().trimRight();
}

void main() {
  stdout.writeln('renderScreenForModel（与 lib 实现同源）');

  final basic = render({
    'ok': true,
    'package': 'com.hexin.plat.android',
    'size': [1080, 2400],
    'elements': [
      {
        'ref': '@e1',
        'role': 'input',
        'name': '搜索股票',
        'center': [540, 200],
        'clickable': true,
        'editable': true,
      },
      {
        'ref': '@e2',
        'role': 'text',
        'name': '上证指数 3200.11 +0.52%',
        'center': [300, 400],
        'clickable': false,
      },
    ],
  });
  check('带包名与尺寸', basic.contains('com.hexin.plat.android') && basic.contains('1080×2400'), basic);
  check('带 ref 与坐标', basic.contains('@e1 input「搜索股票」@540,200'), basic);
  check('标出可点/可输入', basic.contains('可点') && basic.contains('可输入'), basic);

  final failed = render({'ok': false, 'error': 'accessibility_off', 'message': '请先开启无障碍'});
  check('失败带错误码', failed.contains('读屏失败') && failed.contains('accessibility_off'), failed);
  check('失败带提示', failed.contains('请先开启无障碍'), failed);

  final many = {
    'ok': true,
    'size': [1080, 2400],
    'elements': [
      for (var i = 0; i < 120; i++)
        {
          'ref': '@e$i',
          'role': 'text',
          'name': '条目$i',
          'center': [0, i],
          'clickable': false,
        },
    ],
  };
  final cut = render(many, maxElements: 3);
  check('告知总数', cut.contains('共 120 个元素'), cut);
  check('告知截断数量', cut.contains('只列前 3 个'), cut);
  check('保留前 3 条', cut.contains('@e2') && !cut.contains('@e3 '), cut);

  final dup = render({
    'ok': true,
    'size': [1080, 2400],
    'elements': [
      {
        'ref': '@e1',
        'role': 'text',
        'name': '贵州茅台 1500.00',
        'center': [1, 1],
        'clickable': false,
      },
      {
        'ref': '@e2',
        'role': 'text',
        'name': '贵州茅台 1500.00',
        'center': [1, 1],
        'clickable': false,
      },
    ],
  });
  check('相邻重复只留一条', '贵州茅台'.allMatches(dup).length == 1, dup);

  final loose = <Object?, Object?>{
    'ok': true,
    'package': 'x',
    'size': [100, 200],
    'elements': <Object?>[
      <Object?, Object?>{
        'ref': '@e1',
        'role': 'text',
        'name': '甲',
        'center': [1, 1],
      },
    ],
  };
  final looseText = render(loose);
  check('Map<Object?,Object?> 也能读', looseText.contains('@e1') && looseText.contains('甲'), looseText);

  stdout.writeln(_failures == 0 ? '\n全部通过' : '\n$_failures 项失败');
  if (_failures != 0) exitCode = 1;
}
