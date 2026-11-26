// 本地自检：`dart run tool/tool_output_check.dart`
// CI 里由 test/tool_output_clip_test.dart 做正式门禁，两边用例保持一致。
// ignore_for_file: avoid_print, avoid_relative_lib_imports

import '../lib/ai/tool_output_clip.dart';

int _fail = 0;

void _check(bool ok, String what) {
  if (!ok) {
    _fail++;
    print('✗ $what');
  }
}

void main() {
  _check(toolOutputForModel('{"price":70.49}') == '{"price":70.49}', '短结果原样返回');
  _check(toolOutputForModel(null) == '', 'null 当空串');
  _check(toolOutputForModel('') == '', '空串原样');

  final exact = 'x' * kToolOutputLimit;
  _check(toolOutputForModel(exact) == exact, '刚好等于上限不截断');

  final long = '${'A' * kToolOutputKeep}${'B' * 5000}';
  final out = toolOutputForModel(long);
  _check(out.length < long.length, '超长要截短');
  _check(out.startsWith('A' * 100), '保留开头');
  _check(out.contains('结果过长已截断'), '要写明被截断');
  _check(out.contains('${long.length}'), '要写原始长度');
  _check(out.contains('5000'), '要写省略长度');
  _check(out.contains('股票数量'), '要给出缩小方式');

  print(_fail == 0 ? '✓ 全部通过' : '✗ $_fail 条失败');
}
