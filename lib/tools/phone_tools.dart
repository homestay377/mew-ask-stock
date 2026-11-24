/// 手机操控工具：把系统无障碍服务的能力暴露给模型。
///
/// 挂载点：`ChatController._collectTools()` 里 `...buildPhoneTools(...)`。
/// 与股票工具同构（`AppTool`），不碰工具循环本身。
///
/// ## 设计边界
///
/// - **原子动作，不做编排**：模型自己"读屏 → 决定点哪 → 再读屏"。
///   这类任务本来就该由模型一步步判断，工具里写死流程只会在界面变动时卡住。
/// - **每次读屏都是真实界面**：不缓存，因为用户随时可能在动屏幕。
/// - **截断而不是分页**：元素多时截断并提示模型用 [mini_phone_find] 定向查找，
///   比一次性塞几百个元素省 token。
/// - **写动作都有返回值**：`ok` 只表示动作下发成功，不表示目标响应了。
///   模型必须再读一次屏确认（工具描述里写明了）。
library;

import 'dart:io';

import '../core/util.dart';
import 'mini_phone_channel.dart';
import 'tool.dart';

/// 元素表一次给模型看多少个（再多就让它用 find 定向找）。
const int kPhoneMaxElements = 80;

/// 工具集需要的外部依赖，测试里可以替换。
class PhoneToolDeps {
  PhoneToolDeps({MiniPhoneChannel? channel}) : channel = channel ?? MiniPhoneChannel();

  final MiniPhoneChannel channel;
}

/// 构造手机操控工具集。
///
/// [enabled] 为 false 时返回空列表（设置里可以一键关掉）。
List<AppTool> buildPhoneTools({bool enabled = true, PhoneToolDeps? deps}) {
  if (!enabled) return const [];
  if (!Platform.isAndroid) return const [];
  final d = deps ?? PhoneToolDeps();
  final ch = d.channel;

  /// 统一的"没开无障碍"提示：直接告诉用户怎么开，而不是让模型猜。
  Future<String?> requireConnected() async {
    if (await ch.connected()) return null;
    await ch.openAccessibilitySettings();
    return '无障碍服务还没开启。我已经帮你打开了系统设置页：'
        '请找到「问股操控」并打开，然后再让我试一次。';
  }

  Future<String> doObserve({bool resourceIds = false, int maxElements = kPhoneMaxElements}) async {
    final off = await requireConnected();
    if (off != null) return off;
    final screen = await ch.observe(resourceIds: resourceIds);
    return renderScreenForModel(screen, maxElements: maxElements);
  }

  /// 动作之后自动跟一次读屏：模型不必再多花一轮。
  Future<String> actThenLook(String what, Future<Map<String, dynamic>> Function() act) async {
    final off = await requireConnected();
    if (off != null) return off;
    final r = await act();
    if (r['ok'] != true) {
      return '$what 没有执行成功：${r['error'] ?? 'unknown'}${r['message'] == null ? '' : '（${r['message']}）'}';
    }
    // 界面切换需要一点时间；这里不 sleep，靠读屏本身的新鲜度（原生每次都会重拍）
    final screen = await ch.observe();
    return '$what 已下发。\n\n${renderScreenForModel(screen)}';
  }

  return [
    AppTool(
      name: 'mini_phone_observe',
      displayName: '看手机屏幕',
      description:
          '读取当前手机屏幕上的元素（文字、按钮、输入框）与坐标。'
          '每条带一个 ref（如 @e12），点击用它。ref 只在这一次读屏内有效，'
          '任何点击/输入之后都要重新 observe 再取新 ref。',
      parameters: objectSchema({
        'resourceIds': strProp('是否带上 Android resourceId（排查用，默认 false）'),
        'maxElements': intProp('最多返回多少个元素，默认 $kPhoneMaxElements'),
      }),
      promptHint:
          '要操作手机先看屏。看到目标后用 mini_phone_tap 点它的 ref；'
          '元素太多没在列表里时，用 mini_phone_find 按文字找。',
      execute: (args) => doObserve(
        resourceIds: args['resourceIds'] == true,
        maxElements: (args['maxElements'] as num?)?.toInt() ?? kPhoneMaxElements,
      ),
    ),
    AppTool(
      name: 'mini_phone_find',
      displayName: '在屏幕上找元素',
      description:
          '在当前屏幕上按文字/描述查找元素，返回匹配项及其 ref。'
          '比 observe 更省 token，用于长列表、聊天记录、行情列表这类元素很多的界面。',
      parameters: objectSchema({'text': strProp('要匹配的文字（包含即可，不区分大小写）')}, required: ['text']),
      execute: (args) async {
        final off = await requireConnected();
        if (off != null) return off;
        final q = '${args['text'] ?? ''}'.trim().toLowerCase();
        if (q.isEmpty) return '需要给出 text。';
        final screen = await ch.observe();
        if (screen['ok'] != true) return '读屏失败：${screen['error']}';
        final all = (screen['elements'] as List?) ?? const [];
        final hits = all.where((e) {
          final m = (e as Map).cast<String, dynamic>();
          return '${m['name'] ?? ''}'.toLowerCase().contains(q) || '${m['resourceId'] ?? ''}'.toLowerCase().contains(q);
        }).toList();
        if (hits.isEmpty) {
          return '当前屏幕上没有匹配「${args['text']}」的元素（共 ${all.length} 个）。可能藏在下面，先 mini_phone_scroll 再看一次。';
        }
        final buf = StringBuffer('匹配「${args['text']}」的元素 ${hits.length} 个：');
        for (final e in hits.take(20)) {
          final m = (e as Map).cast<String, dynamic>();
          final c = (m['center'] as List?) ?? const [0, 0];
          buf.write(
            '\n${m['ref']} ${m['role']}「${m['name']}」@${c[0]},${c[1]}'
            '${m['clickable'] == true ? ' [可点]' : ''}${m['editable'] == true ? ' [可输入]' : ''}',
          );
        }
        return buf.toString();
      },
    ),
    AppTool(
      name: 'mini_phone_tap',
      displayName: '点击屏幕',
      description:
          '点击屏幕上某个元素。优先传 ref（来自 observe/find）；'
          'ref 用不了时传 x/y 绝对坐标。动作完成后会自动再读一次屏给你看结果。',
      parameters: objectSchema({
        'ref': strProp('元素编号，如 @e12'),
        'x': intProp('X 坐标（像素）'),
        'y': intProp('Y 坐标（像素）'),
        'long': strProp('传 "true" 表示长按', enumValues: ['true', 'false']),
      }),
      execute: (args) async {
        final ref = '${args['ref'] ?? ''}'.trim();
        final long = args['long'] == 'true' || args['long'] == true;
        if (ref.isNotEmpty) {
          return actThenLook(long ? '长按 $ref' : '点击 $ref', () async {
            if (long) {
              // 长按需要坐标：先读屏拿中心点
              final s = await ch.observe();
              final hit = ((s['elements'] as List?) ?? const []).firstWhere(
                (e) => '${(e as Map)['ref']}' == ref,
                orElse: () => null,
              );
              if (hit == null) return {'ok': false, 'error': 'stale_ref', 'message': 'ref 已过期，请重新读屏'};
              final c = (hit['center'] as List?) ?? const [0, 0];
              return ch.longPress((c[0] as num).toInt(), (c[1] as num).toInt());
            }
            return ch.tapRef(ref);
          });
        }
        final x = (args['x'] as num?)?.toInt();
        final y = (args['y'] as num?)?.toInt();
        if (x == null || y == null) return '需要 ref，或者 x 和 y。';
        return actThenLook(long ? '长按 ($x,$y)' : '点击 ($x,$y)', () => long ? ch.longPress(x, y) : ch.tap(x, y));
      },
    ),
    AppTool(
      name: 'mini_phone_type',
      displayName: '输入文字',
      description:
          '往当前屏幕的输入框里输入文字。传 ref 定位输入框（来自 observe）；'
          '不传则写入当前聚焦的输入框。clear 为 true 时先清空原有内容。'
          '注意：搜索框输入后通常还要点"搜索"按钮。',
      parameters: objectSchema(
        {
          'ref': strProp('输入框的编号'),
          'text': strProp('要输入的文字'),
          'clear': strProp('是否先清空，默认 false', enumValues: ['true', 'false']),
          'submit': strProp('是否输入后点键盘搜索/发送（先试）,默认 false', enumValues: ['true', 'false']),
        },
        required: ['text'],
      ),
      execute: (args) async {
        final text = '${args['text'] ?? ''}';
        if (text.isEmpty) return '需要给出 text。';
        final ref = '${args['ref'] ?? ''}'.trim();
        if (ref.isEmpty) return '需要 ref：先用 mini_phone_observe 看清楚输入框的编号。';
        final r = await actThenLook(
          '输入到 $ref',
          () => ch.typeText(ref, text, clear: args['clear'] == 'true' || args['clear'] == true),
        );
        return r;
      },
    ),
    AppTool(
      name: 'mini_phone_scroll',
      displayName: '滚动屏幕',
      description:
          '在当前界面上滑动。默认用屏幕中心上下滑动一屏；'
          '也可以给坐标做任意方向的滑动。动作后自动再读一次屏。',
      parameters: objectSchema({
        'direction': strProp('方向', enumValues: ['up', 'down', 'left', 'right']),
        'amount': intProp('滑动距离（像素），默认 600'),
        'x1': intProp('起点 X（可选，给了就用自定义滑动）'),
        'y1': intProp('起点 Y'),
        'x2': intProp('终点 X'),
        'y2': intProp('终点 Y'),
      }),
      execute: (args) async {
        final off = await requireConnected();
        if (off != null) return off;
        final x1 = (args['x1'] as num?)?.toInt();
        final y1 = (args['y1'] as num?)?.toInt();
        final x2 = (args['x2'] as num?)?.toInt();
        final y2 = (args['y2'] as num?)?.toInt();
        if (x1 != null && y1 != null && x2 != null && y2 != null) {
          return actThenLook('滑动 ($x1,$y1)→($x2,$y2)', () => ch.swipe(x1, y1, x2, y2));
        }
        final screen = await ch.observe();
        final size = (screen['size'] as List?) ?? const [1080, 2400];
        final w = (size[0] as num).toInt();
        final h = (size[1] as num).toInt();
        final amount = ((args['amount'] as num?)?.toInt() ?? 600).clamp(100, h);
        final dir = '${args['direction'] ?? 'down'}';
        final cx = w ~/ 2;
        final cy = h ~/ 2;
        final (sx, sy, ex, ey) = switch (dir) {
          'up' => (cx, cy - amount ~/ 2, cx, cy + amount ~/ 2),
          'left' => (cx + amount ~/ 2, cy, cx - amount ~/ 2, cy),
          'right' => (cx - amount ~/ 2, cy, cx + amount ~/ 2, cy),
          // "down" = 看下面的内容 = 手指往上划
          _ => (cx, cy + amount ~/ 2, cx, cy - amount ~/ 2),
        };
        return actThenLook('向$dir 滑动', () => ch.swipe(sx, sy, ex, ey, durationMs: 320));
      },
    ),
    AppTool(
      name: 'mini_phone_press',
      displayName: '按系统键',
      description: '按手机的返回 / 主页 / 最近任务键。返回后会自动再读一次屏。',
      parameters: objectSchema(
        {
          'key': strProp('哪个键', enumValues: ['back', 'home', 'recents']),
        },
        required: ['key'],
      ),
      execute: (args) async {
        final key = '${args['key'] ?? 'back'}';
        return actThenLook(
          '按 $key 键',
          () => switch (key) {
            'home' => ch.home(),
            'recents' => ch.recents(),
            _ => ch.back(),
          },
        );
      },
    ),
    AppTool(
      name: 'mini_phone_open',
      displayName: '打开 App 或链接',
      description:
          '打开已安装的 App（传包名，如 com.hexin.plat.android 同花顺），或者用某个 App 打开一个链接。'
          '打开后会自动读一次屏，你就能看到界面了。',
      parameters: objectSchema({'package': strProp('App 包名'), 'url': strProp('要打开的链接（可选）')}),
      execute: (args) async {
        final off = await requireConnected();
        if (off != null) return off;
        final pkg = '${args['package'] ?? ''}'.trim();
        final url = '${args['url'] ?? ''}'.trim();
        if (pkg.isEmpty && url.isEmpty) return '需要 package 或 url。';
        if (url.isNotEmpty) {
          return actThenLook('打开链接 $url', () => ch.openUrl(url, package: pkg.isEmpty ? null : pkg));
        }
        return actThenLook('打开 $pkg', () => ch.openApp(pkg));
      },
    ),
  ];
}
