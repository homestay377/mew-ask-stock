import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/data/assistant.dart';
import 'package:mewhub/tools/mini_phone_channel.dart';

void main() {
  group('renderScreenForModel', () {
    test('列出元素并用 ref 标出可点击项', () {
      final screen = {
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
        'windows': const [],
      };
      final text = renderScreenForModel(screen);
      expect(text, contains('com.hexin.plat.android'));
      expect(text, contains('@e1 input「搜索股票」@540,200'));
      expect(text, contains('可点'));
      expect(text, contains('可输入'));
      expect(text, contains('@e2 text「上证指数 3200.11 +0.52%」'));
    });

    test('读屏失败时说明原因，不说"空屏幕"', () {
      final text = renderScreenForModel({'ok': false, 'error': 'accessibility_off', 'message': '请先开启无障碍'});
      expect(text, contains('读屏失败'));
      expect(text, contains('accessibility_off'));
      expect(text, contains('请先开启无障碍'));
    });

    test('超过上限时截断并告知总数', () {
      final elements = [
        for (var i = 0; i < 120; i++)
          {
            'ref': '@e$i',
            'role': 'text',
            'name': '条目$i',
            'center': [0, i],
            'clickable': false,
          },
      ];
      final text = renderScreenForModel({
        'ok': true,
        'size': [1080, 2400],
        'elements': elements,
      }, maxElements: 3);
      expect(text, contains('共 120 个元素'));
      expect(text, contains('只列前 3 个'));
      expect(text, contains('@e2'));
      expect(text, isNot(contains('@e3 ')));
    });

    test('相邻重复条目只留第一条（列表滚动常见）', () {
      final screen = {
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
      };
      final text = renderScreenForModel(screen);
      expect('贵州茅台'.allMatches(text).length, 1);
    });
  });

  group('Assistant.enablePhoneControl', () {
    test('默认关闭，序列化往返保留取值', () {
      final a = Assistant(id: 'x', name: 'x');
      expect(a.enablePhoneControl, isFalse);
      final on = a.copyWith(enablePhoneControl: true);
      expect(Assistant.fromJson(on.toJson()).enablePhoneControl, isTrue);
      expect(Assistant.fromJson(a.toJson()).enablePhoneControl, isFalse);
    });

    test('手机操控与股票分析互相独立', () {
      final a = Assistant(id: 'x', name: 'x').copyWith(enablePhoneControl: true);
      expect(a.enableStockTools, isFalse);
      expect(a.copyWith(enableStockTools: true).enablePhoneControl, isTrue);
    });
  });
}
