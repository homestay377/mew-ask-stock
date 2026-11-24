import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/data/assistant.dart';
import 'package:mewhub/tools/virtual_display_channel.dart';

void main() {
  group('VirtualDisplayStatus', () {
    test('就绪时 describe 带 displayId', () {
      final s = VirtualDisplayStatus.fromMap({
        'shizuku': 'ready',
        'shizukuReady': true,
        'display': {'ok': true, 'phase': 'ready', 'displayId': 7},
        'accessibility': true,
      });
      expect(s.usable, isTrue);
      expect(s.displayId, 7);
      expect(s.describe(), contains('display=7'));
      expect(s.describe(), contains('无障碍已连'));
    });

    test('Shizuku 没运行 / 没授权分别给出不同的下一步', () {
      final off = VirtualDisplayStatus.fromMap({'shizuku': 'not_running', 'shizukuReady': false});
      final perm = VirtualDisplayStatus.fromMap({'shizuku': 'need_permission', 'shizukuReady': false});
      expect(off.usable, isFalse);
      expect(off.describe(), contains('没在运行'));
      expect(perm.describe(), contains('授权'));
      expect(off.describe(), isNot(perm.describe()));
    });

    test('Shizuku 就绪但建屏失败时报告失败原因', () {
      final s = VirtualDisplayStatus.fromMap({
        'shizuku': 'ready',
        'shizukuReady': true,
        'display': {'ok': false, 'phase': 'failed', 'detail': 'createVirtualDisplay rejected'},
      });
      expect(s.usable, isFalse);
      expect(s.describe(), contains('createVirtualDisplay rejected'));
    });

    test('不支持的平台说不支持，不说"状态未知"', () {
      expect(VirtualDisplayStatus.unsupported().describe(), contains('不支持'));
    });
  });

  group('Assistant.enableVirtualDisplay', () {
    test('默认关闭，与手机操控互相独立', () {
      final a = Assistant(id: 'x', name: 'x');
      expect(a.enableVirtualDisplay, isFalse);
      expect(a.copyWith(enableVirtualDisplay: true).enablePhoneControl, isFalse);
      expect(a.copyWith(enablePhoneControl: true).enableVirtualDisplay, isFalse);
    });

    test('序列化往返保留取值', () {
      final on = Assistant(id: 'x', name: 'x').copyWith(enableVirtualDisplay: true);
      expect(Assistant.fromJson(on.toJson()).enableVirtualDisplay, isTrue);
      expect(Assistant.fromJson(Assistant(id: 'y', name: 'y').toJson()).enableVirtualDisplay, isFalse);
    });
  });
}
