import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';

/// 工具结果发往模型前会被裁剪（见 [toolOutputForModel]）。
///
/// 存储和界面保留全文，只有发往 provider 的那一份被截——
/// 否则 `stock_levels` 的 8 只 × 5 周期、`http_request` 抓的整页 HTML
/// 会把前面的对话挤掉，表现是模型「忘了刚才说过什么」。
void main() {
  test('短结果原样返回，不做任何改动', () {
    const s = '{"price":70.49}';
    expect(toolOutputForModel(s), s);
  });

  test('null 与空串都当空串处理', () {
    expect(toolOutputForModel(null), '');
    expect(toolOutputForModel(''), '');
  });

  test('刚好等于上限时不截断', () {
    final s = 'x' * kToolOutputLimit;
    expect(toolOutputForModel(s).length, kToolOutputLimit);
    expect(toolOutputForModel(s), s);
  });

  test('超过上限时保留开头，并在尾部说明省略了多少', () {
    final s = '${'A' * kToolOutputKeep}${'B' * 5000}';
    final out = toolOutputForModel(s);
    expect(out.length, lessThan(s.length));
    expect(out.startsWith('A' * 100), isTrue);
    expect(out.contains('结果过长已截断'), isTrue);
    // 原始长度与省略长度都要写出来，模型才知道该缩小范围而不是继续读
    expect(out.contains('${s.length}'), isTrue);
    expect(out.contains('5000'), isTrue);
  });

  test('提示里给出可执行的缩小方式', () {
    final out = toolOutputForModel('x' * (kToolOutputLimit + 1));
    expect(out.contains('股票数量'), isTrue);
    expect(out.contains('周期'), isTrue);
  });
}
