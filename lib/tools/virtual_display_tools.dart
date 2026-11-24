/// 虚拟屏工具：AI 在**后台看不见的一块屏**上打开别的 App（同花顺、雪球、通达信…），
/// 读界面、点按钮、翻页，全程不打断你正在用的主屏。
///
/// 和 [buildPhoneTools]（无障碍，直接操作主屏）的分工：
/// - 主屏工具：能用但会挡住用户，适合"就一下"的动作；
/// - 虚拟屏工具：默认选择，不挡人。所有读界面都走虚拟屏。
///
/// 前提：Shizuku 服务在跑并授权（或无线调试配对后由 App 自己拉起助手）。
/// 没就绪时工具**仍然下发**，但会返回明确的一步提示，让模型告诉用户去开。
library;

import 'dart:io';

import 'tool.dart';
import 'mini_phone_channel.dart';
import 'virtual_display_channel.dart';

/// 一次给模型看多少个元素（再多就让它用 find 定向找）。
const int kVirtualMaxElements = 80;

class VirtualDisplayDeps {
  VirtualDisplayDeps({VirtualDisplayChannel? vd, MiniPhoneChannel? phone})
    : vd = vd ?? VirtualDisplayChannel(),
      phone = phone ?? MiniPhoneChannel();

  final VirtualDisplayChannel vd;
  final MiniPhoneChannel phone;
}

/// 构造虚拟屏工具集。
List<AppTool> buildVirtualDisplayTools({bool enabled = true, VirtualDisplayDeps? deps}) {
  if (!enabled) return const [];
  if (!Platform.isAndroid) return const [];
  final d = deps ?? VirtualDisplayDeps();

  /// 统一的"还没就绪"提示：说清缺哪一步，不要笼统报错。
  Future<String?> requireDisplay() async {
    final st = await d.vd.status();
    if (st.usable) return null;
    return '虚拟屏还没就绪。${st.describe()}\n'
        '（需要：Shizuku 服务运行中 + 给问股授权；或在设置里完成无线调试配对）';
  }

  /// 读虚拟屏：先试无障碍树（有文字和 ref），拿不到元素时退回截图。
  Future<String> readScreen({int maxElements = kVirtualMaxElements, bool withImage = false}) async {
    final st = await d.vd.status();
    if (!st.usable) return st.describe();
    final snap = await d.phone.observe(displayId: st.displayId, resourceIds: false);
    final elements = (snap['elements'] as List?) ?? const [];
    if (snap['ok'] == true && elements.isNotEmpty) {
      return renderScreenForModel(snap, maxElements: maxElements);
    }
    // 树是空的：App 可能还没画完，或者它用了不暴露无障碍的自绘界面
    if (withImage) {
      final png = await d.vd.screenshot();
      if (png != null) {
        return '虚拟屏上没有可读的文字节点（App 可能还没启动完，或界面是自绘的）。'
            '已截一张图，尺寸 ${png.length} 字节；可以再等一会重试 mini_vd_observe。';
      }
    }
    return '虚拟屏上现在没有可读内容（display=${st.displayId}）。'
        '如果还没打开 App，先 mini_vd_open；打开后等 1-2 秒再 mini_vd_observe。';
  }

  /// 动作之后自动再读一次屏，模型不用多花一轮确认。
  Future<String> actThenLook(String what, Future<Map<String, dynamic>> Function() act) async {
    final r = await act();
    if (r['ok'] != true) {
      final err = r['error'] ?? 'unknown';
      final detail = r['detail'] ?? r['message'];
      return '$what 没有成功：$err${detail == null ? '' : '（$detail）'}';
    }
    // 界面切换需要时间；这里给一个很短的让路，避免读到动作前的帧
    await Future<void>.delayed(const Duration(milliseconds: 350));
    return '$what 已下发。\n\n${await readScreen()}';
  }

  return [
    AppTool(
      name: 'vd_status',
      displayName: '虚拟屏状态',
      description:
          '查看虚拟屏现在能不能用：Shizuku 有没有跑、有没有授权、屏建没建起来。'
          '别的情况（打不开 App、读不到界面）先用它确认前提，不要瞎猜。',
      parameters: objectSchema({}),
      execute: (_) async {
        final st = await d.vd.status();
        final buf = StringBuffer(st.describe());
        if (st.shizukuDetail != null) buf.write('\nShizuku 细节：${st.shizukuDetail}');
        if (st.displayDetail != null) buf.write('\n虚拟屏细节：${st.displayDetail}');
        return buf.toString();
      },
    ),
    AppTool(
      name: 'vd_prepare',
      displayName: '准备虚拟屏',
      description:
          '让虚拟屏准备好（Shizuku 授权 → 绑定 → 建屏）。'
          '需要用户去开 Shizuku 或点授权时，会把那一步说出来。',
      parameters: objectSchema({}),
      execute: (_) async {
        final st = await d.vd.status();
        if (!st.shizukuReady) {
          switch (st.shizuku) {
            case 'not_installed':
              return '没检测到 Shizuku。两条路：① 安装 Shizuku 并启动服务；② 用无线调试配对，让我自己拉起助手。';
            case 'not_running':
              await d.vd.openShizuku();
              return 'Shizuku 已安装但没在运行，我已经帮你打开了 Shizuku，请在里面点「启动服务」；好了再让我准备一次。';
            case 'need_permission':
              await d.vd.requestPermission();
              return '已向 Shizuku 请求授权，请在弹窗里点「允许」；好了再让我准备一次。';
            default:
              return 'Shizuku 状态：${st.describe()}';
          }
        }
        final r = await d.vd.ensureDisplay();
        if (r['ok'] == true) {
          final st2 = await d.vd.status();
          return '虚拟屏已就绪（display=${st2.displayId}）。'
              '${st2.accessibility ? '' : '注意：无障碍没连，读不到界面文字，只能截图。'}';
        }
        return '建虚拟屏失败：${r['error'] ?? ''} ${r['detail'] ?? ''}'.trim();
      },
    ),
    AppTool(
      name: 'vd_open',
      displayName: '在虚拟屏打开 App',
      description:
          '在虚拟屏上打开手机里的 App，用中文名或包名都可以'
          '（如「同花顺」「雪球」「com.hexin.plat.android」）。会自动准备好虚拟屏。'
          '打开后自动读一次屏告诉你看到了什么。',
      parameters: objectSchema({'app': strProp('App 名字或包名，例如 同花顺 / 雪球 / com.xueqiu.android')}, required: ['app']),
      promptHint:
          '需要看接口拿不到的行情（行业资金流、龙虎榜席位、F10 里没 API 的字段）时，'
          '用 vd_open 打开对应 App 读界面；能走 stock_kline / analyze_chan / stock_levels 的，优先走它们，不要开 App。',
      execute: (args) async {
        final raw = '${args['app'] ?? ''}'.trim();
        if (raw.isEmpty) return '需要给出 app（名字或包名）。';
        final st = await d.vd.status();
        if (!st.usable) {
          final prep = await d.vd.ensureDisplay();
          if (prep['ok'] != true) {
            final after = await d.vd.status();
            return '虚拟屏没准备好，打不开 App。${after.describe()}';
          }
        }
        // 名字 → 包名：让原生用 PackageManager 查（和模型自己猜包名比，这个准）
        final resolve = await d.phone.findApp(raw);
        if (resolve['ok'] != true) {
          return resolve['detail']?.toString() ?? '找不到叫「$raw」的 App。';
        }
        final matches = (resolve['apps'] as List?) ?? const [];
        if (matches.isEmpty) {
          final installed = (resolve['suggest'] as List?) ?? const [];
          if (installed.isNotEmpty) {
            final names = installed.take(12).map((e) => '${(e as Map)['label']}(${e['package']})').join('、');
            return '没找到「$raw」。手机上相近的有：$names';
          }
          return '没找到「$raw」，也没找到相近的 App。可以先 mini_vd_apps 看看装了什么。';
        }
        final best = (matches.first as Map);
        final pkg = '${best['package']}';
        final label = '${best['label']}';
        final r = await d.vd.startApp(pkg);
        if (r['ok'] != true) {
          return '打开 $label（$pkg）失败：${r['error'] ?? ''} ${r['detail'] ?? ''}'.trim();
        }
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        return '已在虚拟屏打开 $label（$pkg）。\n\n${await readScreen()}';
      },
    ),
    AppTool(
      name: 'vd_apps',
      displayName: '列出已装 App',
      description:
          '列出手机里能打开的 App（名字 + 包名）。不确定某个 App 叫什么时用它，'
          '比猜包名靠谱。默认只列行情/股票相关的，可以给 keyword 过滤。',
      parameters: objectSchema({
        'keyword': strProp('按名字或包名过滤，例如 股票 / 同花顺'),
        'all': strProp('传 "true" 列出全部（可能上百个）', enumValues: ['true', 'false']),
      }),
      execute: (args) async {
        final kw = '${args['keyword'] ?? ''}'.trim();
        final all = args['all'] == 'true' || args['all'] == true;
        final r = await d.phone.listApps();
        if (r['ok'] != true) return '读不到 App 列表：${r['error']}';
        var apps = ((r['apps'] as List?) ?? const []).map((e) => (e as Map)).toList();
        if (kw.isNotEmpty) {
          final q = kw.toLowerCase();
          apps = apps
              .where((a) => '${a['label']}'.toLowerCase().contains(q) || '${a['package']}'.toLowerCase().contains(q))
              .toList();
        } else if (!all) {
          apps = apps.where((a) => _looksLikeMarket('${a['label']}')).toList();
        }
        if (apps.isEmpty) return kw.isEmpty ? '没找到行情相关的 App（可以用 all=true 看全部）。' : '没有匹配「$kw」的 App。';
        final buf = StringBuffer('找到 ${apps.length} 个：');
        for (final a in apps.take(40)) {
          buf.write('\n- ${a['label']}（${a['package']}）');
        }
        return buf.toString();
      },
    ),
    AppTool(
      name: 'vd_observe',
      displayName: '看虚拟屏',
      description:
          '读虚拟屏当前界面：元素（文字、按钮、输入框）与坐标，每条带 ref。'
          'ref 只在这次读屏内有效，点击后要重新 observe。',
      parameters: objectSchema({'maxElements': intProp('最多返回多少个元素，默认 $kVirtualMaxElements')}),
      execute: (args) async {
        final off = await requireDisplay();
        if (off != null) return off;
        final n = (args['maxElements'] as num?)?.toInt() ?? kVirtualMaxElements;
        return readScreen(maxElements: n, withImage: true);
      },
    ),
    AppTool(
      name: 'vd_find',
      displayName: '在虚拟屏找元素',
      description: '在虚拟屏上按文字查元素，返回 ref。比 vd_observe 省 token，适合长列表（行情列表、公告、F10）。',
      parameters: objectSchema({'text': strProp('要匹配的文字')}, required: ['text']),
      execute: (args) async {
        final off = await requireDisplay();
        if (off != null) return off;
        final st = await d.vd.status();
        final q = '${args['text'] ?? ''}'.trim().toLowerCase();
        if (q.isEmpty) return '需要 text。';
        final snap = await d.phone.observe(displayId: st.displayId);
        if (snap['ok'] != true) return '读虚拟屏失败：${snap['error']}';
        final all = (snap['elements'] as List?) ?? const [];
        final hits = all.where((e) {
          final m = (e as Map);
          return '${m['name'] ?? ''}'.toLowerCase().contains(q) || '${m['resourceId'] ?? ''}'.toLowerCase().contains(q);
        }).toList();
        if (hits.isEmpty) {
          return '虚拟屏上没有匹配「${args['text']}」的元素（共 ${all.length} 个）。可能在下面，先 vd_scroll 再看。';
        }
        final buf = StringBuffer('匹配 ${hits.length} 个：');
        for (final e in hits.take(20)) {
          final m = (e as Map);
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
      name: 'vd_tap',
      displayName: '点虚拟屏',
      description: '点虚拟屏上的元素（传 ref）或坐标。动作后自动再读一次屏。',
      parameters: objectSchema({
        'ref': strProp('元素编号，如 @e12'),
        'x': intProp('X 坐标（虚拟屏像素）'),
        'y': intProp('Y 坐标（虚拟屏像素）'),
      }),
      execute: (args) async {
        final off = await requireDisplay();
        if (off != null) return off;
        final st = await d.vd.status();
        final ref = '${args['ref'] ?? ''}'.trim();
        if (ref.isNotEmpty) {
          // ref 是主屏/虚拟屏通用的读屏编号，点击仍走虚拟屏的注入
          final snap = await d.phone.observe(displayId: st.displayId);
          final hit = ((snap['elements'] as List?) ?? const []).firstWhere(
            (e) => '${(e as Map)['ref']}' == ref,
            orElse: () => null,
          );
          if (hit == null) return 'ref $ref 已过期（界面变了），先 vd_observe 再看一次。';
          final c = (hit['center'] as List?) ?? const [0, 0];
          final x = (c[0] as num).toInt();
          final y = (c[1] as num).toInt();
          return actThenLook('点 $ref「${hit['name']}」', () => d.vd.tap(x, y));
        }
        final x = (args['x'] as num?)?.toInt();
        final y = (args['y'] as num?)?.toInt();
        if (x == null || y == null) return '需要 ref，或者 x 和 y。';
        return actThenLook('点 ($x,$y)', () => d.vd.tap(x, y));
      },
    ),
    AppTool(
      name: 'vd_scroll',
      displayName: '滚虚拟屏',
      description: '在虚拟屏上滚动。方向 "down" 表示看下面的内容。动作后自动读一次屏。',
      parameters: objectSchema({
        'direction': strProp('方向', enumValues: ['up', 'down', 'left', 'right']),
        'amount': intProp('滑动距离（像素），默认 600'),
      }),
      execute: (args) async {
        final off = await requireDisplay();
        if (off != null) return off;
        final st = await d.vd.status();
        final snap = await d.phone.observe(displayId: st.displayId);
        final size = (snap['size'] as List?) ?? const [1080, 2400];
        final w = (size[0] as num).toInt();
        final h = (size[1] as num).toInt();
        final amount = ((args['amount'] as num?)?.toInt() ?? 600).clamp(100, h);
        final cx = w ~/ 2;
        final cy = h ~/ 2;
        final dir = '${args['direction'] ?? 'down'}';
        final (sx, sy, ex, ey) = switch (dir) {
          'up' => (cx, cy - amount ~/ 2, cx, cy + amount ~/ 2),
          'left' => (cx + amount ~/ 2, cy, cx - amount ~/ 2, cy),
          'right' => (cx - amount ~/ 2, cy, cx + amount ~/ 2, cy),
          _ => (cx, cy + amount ~/ 2, cx, cy - amount ~/ 2),
        };
        return actThenLook('向$dir 滚动', () => d.vd.swipe(sx, sy, ex, ey));
      },
    ),
    AppTool(
      name: 'vd_type',
      displayName: '在虚拟屏输入',
      description: '往虚拟屏的输入框写文字。传 ref 定位；不传则用坐标。',
      parameters: objectSchema({'ref': strProp('输入框的 ref'), 'text': strProp('要输入的文字')}, required: ['text']),
      execute: (args) async {
        final off = await requireDisplay();
        if (off != null) return off;
        final st = await d.vd.status();
        final text = '${args['text'] ?? ''}';
        if (text.isEmpty) return '需要 text。';
        final ref = '${args['ref'] ?? ''}'.trim();
        if (ref.isEmpty) {
          // 没有 ref：先点一下屏幕上的输入框由模型自己给坐标，这里直接报错更清楚
          return '需要 ref：先 vd_observe 看清输入框的编号。';
        }
        final r = await d.phone.typeText(ref, text, displayId: st.displayId, clear: true);
        if (r['ok'] != true) return '输入失败：${r['error']}';
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return '已输入。\n\n${await readScreen()}';
      },
    ),
    AppTool(
      name: 'vd_back',
      displayName: '虚拟屏返回',
      description: '在虚拟屏上按返回键（不会影响你自己的屏幕）。',
      parameters: objectSchema({}),
      execute: (_) async {
        final off = await requireDisplay();
        if (off != null) return off;
        return actThenLook('按返回', () => d.vd.pressKey('back'));
      },
    ),
  ];
}

/// 粗略判断是不是行情类 App（只用于默认过滤，不用于断定身份）。
bool _looksLikeMarket(String label) {
  const hints = ['同花顺', '通达信', '雪球', '开盘啦', '东方财富', '大智慧', '老虎', '富途', '股票', '证券', '行情', '炒股', '涨乐', '自选股', '韭研', '韭圈'];
  return hints.any(label.contains);
}
