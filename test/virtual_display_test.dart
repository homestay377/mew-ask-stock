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

    test('无线调试路线就绪时也能用', () {
      final s = VirtualDisplayStatus.fromMap({
        'shizuku': 'not_installed',
        'shizukuReady': false,
        'wireless': 'ready',
        'wirelessReady': true,
        'source': 'wireless',
        'display': {'ok': true, 'phase': 'ready', 'displayId': 3},
      });
      expect(s.usable, isTrue);
      expect(s.source, 'wireless');
      expect(s.describe(), contains('display=3'));
    });

    test('两条路线都没起来时，服务是就绪但屏没建成要说清', () {
      final s = VirtualDisplayStatus.fromMap({
        'shizuku': 'ready',
        'shizukuReady': true,
        'wireless': 'not_paired',
        'display': {'ok': false, 'phase': 'failed', 'detail': 'createVirtualDisplay rejected'},
      });
      expect(s.usable, isFalse);
      expect(s.describe(), contains('服务已就绪'));
      expect(s.describe(), contains('createVirtualDisplay rejected'));
    });

    test('Shizuku：服务在跑但没授权，和没在运行，分别说清', () {
      final notRunning = VirtualDisplayStatus.fromMap({
        'shizuku': 'not_running',
        'shizukuRunning': false,
        'shizukuGranted': false,
        'shizukuText': 'Shizuku 服务没在运行（打开 Shizuku 点「启动服务」）',
      });
      final noPerm = VirtualDisplayStatus.fromMap({
        'shizuku': 'need_permission',
        'shizukuRunning': true,
        'shizukuGranted': false,
        'shizukuText': '还没给问股授权（在 Shizuku 的应用管理里点允许）',
      });
      expect(notRunning.shizukuRunning, isFalse);
      expect(noPerm.shizukuRunning, isTrue);
      expect(noPerm.shizukuGranted, isFalse);
      expect(notRunning.describe(), contains('没在运行'));
      expect(noPerm.describe(), contains('授权'));
      expect(notRunning.describe(), isNot(noPerm.describe()));
    });

    test('无线调试的失败原因会带出来', () {
      final s = VirtualDisplayStatus.fromMap({
        'shizuku': 'not_running',
        'wireless': 'failed',
        'wirelessDetail': '配对码不对',
      });
      expect(s.wirelessDetail, '配对码不对');
      expect(s.describe(), contains('没在运行'));
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
