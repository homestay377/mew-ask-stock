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

import '../core/paths.dart';
import '../core/virtual_display_overlay_state.dart';
import '../core/virtual_display_shot.dart';
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

  // ── 自动建屏 ──────────────────────────────────────────────────
  // 权限给过之后，用户不该再被要求点「准备虚拟屏」。这里静默建屏，
  // 只有真的缺前提（服务没跑 / 没授权 / 系统拒绝）才把**那一步**报出来。
  var displayId = -1;
  var askedPermission = false;

  /// 连续多少次动作后界面一点没变。用来识别"在打转"：
  /// 一直点、一直没效果，与其烧满 100 个回合，不如早点叫停并说清原因。
  var noProgress = 0;
  Future<String?>? building;

  /// 调一次 `ensure_display`，并对「身份还在绑」这种瞬时状态重试。
  ///
  /// Shizuku 刚授权、刚重启服务时 binder 还没绑上，native 会返回 `shell_unavailable`。
  /// 这时不该告诉用户「没准备好」——它只是还在连。最多等约 6 秒，每次重试都顺手
  /// 触发一次绑定（`refresh` 内部会 bind）。
  Future<Map<String, dynamic>> ensureDisplayWithRetry() async {
    var r = await d.vd.ensureDisplay();
    for (var i = 0; i < 7 && r['ok'] != true; i++) {
      if ('${r['error'] ?? ''}' != 'shell_unavailable') break;
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await d.vd.refresh();
      r = await d.vd.ensureDisplay();
    }
    return r;
  }

  var accessibilityTried = false;

  /// 无障碍服务让读屏能拿到精确控件、也能输入中文。
  ///
  /// Mika 的做法是靠 shell 身份把它写进 secure 设置，用户从不需要去系统设置里点；
  /// 这里照做：每进程只试一次，开不了就算了——读屏会退回本机 OCR（能点，不能打中文）。
  Future<void> ensureAccessibilityOnce() async {
    if (accessibilityTried) return;
    accessibilityTried = true;
    try {
      final st = await d.vd.status();
      if (st.accessibility) return;
      await d.vd.enableAccessibility();
    } catch (_) {
      // 开不了不算错误：OCR 这条路还在，不打断当前动作
    }
  }

  /// 真正建屏的那一步：先尽量补上缺失的服务/授权，再调 ensure_display。
  /// 失败时只说「缺哪一步」，不说笼统的"没准备好"。
  Future<String?> buildOnce({required bool force}) async {
    var st = await d.vd.status();

    // 1) 先把「Shizuku 服务 / 授权」这一步尽量替用户走完。
    if (!st.shizukuReady && !st.wirelessReady) {
      if (st.shizuku == 'need_permission') {
        if (!askedPermission) {
          askedPermission = true;
          await d.vd.requestPermission(); // 弹一次系统授权框，用户点「允许」即可
          await Future<void>.delayed(const Duration(seconds: 3));
          st = await d.vd.status();
        }
        if (!st.shizukuReady && !st.wirelessReady) {
          return '差最后一步：请在 Shizuku 的弹窗里给「问股」点「允许」，之后我自己建屏。${st.describe()}';
        }
      } else if (st.shizuku == 'not_running') {
        await d.vd.openShizuku();
        return 'Shizuku 服务没在运行，我已经帮你打开了 Shizuku：点「启动服务」就行，屏我自己建，不用再点准备。';
      } else if (st.shizuku == 'not_installed') {
        return '这台机器还没装 Shizuku。装好并启动服务（或在设置里用无线调试配对）之后，我自己会建屏。';
      }
    }

    // 2) 建屏。重复调用是安全的：native 侧已经 ready 就直接返回原屏。
    final r = await ensureDisplayWithRetry();
    if (r['ok'] == true) {
      displayId = (r['displayId'] as num?)?.toInt() ?? -1;
      // 第一帧会晚半拍，稍等一下，免得下一句就读到空屏
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return null;
    }

    // 3) 失败：把「原因」和「下一步」分开说，别笼统说没准备好。
    final after = await d.vd.status();
    final detail = '${r['detail'] ?? after.displayDetail ?? ''}'.trim();
    final err = '${r['error'] ?? ''}';
    if (err == 'shell_unavailable') {
      return 'Shizuku 服务还没连上，建不了屏。${detail.isEmpty ? after.describe() : detail}';
    }
    final why = detail.isEmpty ? after.describe() : '${after.describe()}（$detail）';
    return force ? '重建虚拟屏失败：$why' : '虚拟屏没建起来：$why';
  }

  /// 就绪返回 `null`，否则返回「缺哪一步」的一句话。
  ///
  /// 并发调用只建一次屏（Future 锁）：一次对话里几个工具同时触发时，
  /// 不会建出两块屏、也不会互相把对方的 displayId 覆盖掉。
  Future<String?> ensureReady({bool force = false}) async {
    final st = await d.vd.status();
    String? off;
    if (!force && st.usable) {
      displayId = st.displayId;
    } else {
      final inflight = building ??= buildOnce(force: force).whenComplete(() => building = null);
      off = await inflight;
    }
    if (off == null) await ensureAccessibilityOnce();
    return off;
  }

  /// 读虚拟屏。
  ///
  /// 顺序是**有意**的：
  /// 1. **无障碍树**（开了才有效）：有精确控件、ref、可点状态，最适合点按钮；
  /// 2. **本机 OCR**（不需要任何开关）：拿"文字 + 坐标"，行情数字这种纯文本界面够用；
  /// 3. 都不行才说读不到。
  ///
  /// 所以"没开无障碍"不等于用不了——这正是 Mika 的做法。
  /// 在结果前面写明"坐标按这个尺寸算"，避免模型拿截图（缩放预览）的像素当坐标。
  String withSize(VirtualDisplayStatus st, String text) {
    final w = st.displayWidth;
    final h = st.displayHeight;
    if (w == null || h == null) return text;
    VirtualDisplayShot.sizeLabel = '$w×$h';
    return '虚拟屏 $w×$h（坐标都按这个像素尺寸，不是截图尺寸）\n\n$text';
  }

  /// 多模态模型：读屏成功时把这一帧存下来，交给下一轮请求当图片附件。
  /// 不支持视觉的模型不截图（[VirtualDisplayShot.wanted] 为 false），省一次 PNG 编码。
  Future<String> withShot(String text) async {
    if (!VirtualDisplayShot.wanted) return text;
    try {
      final png = await d.vd.screenshot();
      if (png != null) {
        final f = File('${AppPaths.cache.path}/vd_shot.png');
        await f.writeAsBytes(png, flush: false);
        VirtualDisplayShot.offer(f.path);
      }
    } catch (_) {
      // 截图失败不影响文字结果
    }
    return text;
  }

  Future<String> readScreen({
    int maxElements = kVirtualMaxElements,
    bool withImage = false,
    bool retryEmpty = false,
  }) async {
    final off = await ensureReady();
    if (off != null) return off;
    final st = await d.vd.status();
    final id = st.usable ? st.displayId : displayId;

    // 1. 无障碍树
    final snap = await d.phone.observe(displayId: id, resourceIds: false);
    final elements = (snap['elements'] as List?) ?? const [];
    if (snap['ok'] == true && elements.isNotEmpty) {
      return withSize(st, await withShot(renderScreenForModel(snap, maxElements: maxElements)));
    }

    // 2. 本机 OCR。默认只认一次——每次动作都多花 600ms 重试，点起来就是"慢".
    //    只有 vd_observe 这种"要看清"的调用才 retryEmpty。
    var lines = await d.vd.ocr();
    if (lines.isEmpty && retryEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      lines = await d.vd.ocr();
      if (lines.isNotEmpty) {
        return withSize(st, await withShot(renderOcrForModel(lines, maxElements: maxElements)));
      }
    }
    if (lines.isNotEmpty) {
      return withSize(st, await withShot(renderOcrForModel(lines, maxElements: maxElements)));
    }

    // 3. 都没有：说清可能的原因，别谎称"空屏"
    if (withImage) {
      final png = await d.vd.screenshot();
      if (png == null) {
        return '虚拟屏上还没出画面（display=$id）。App 可能刚启动，等 1-2 秒再 vd_observe。';
      }
      return '虚拟屏有画面但没有文字：这页可能是图表/纯图界面，或者还没画完。'
          '无障碍没连的时候只能读文字；这种情况可以给 vd_tap 坐标直接点，或稍等再 vd_observe。';
    }
    return '虚拟屏上现在没有可读内容（display=$id）。'
        '如果还没打开 App，先 vd_open；打开后等 1-2 秒再 vd_observe。';
  }

  /// 动作之后自动再读一次屏，模型不用多花一轮确认。
  Future<String> actThenLook(String what, Future<Map<String, dynamic>> Function() act) async {
    final sw = Stopwatch()..start();
    final before = await d.vd.fingerprint();
    final r = await act();
    if (r['ok'] != true) {
      final err = r['error'] ?? 'unknown';
      final detail = r['detail'] ?? r['message'];
      return '$what 没有成功：$err${detail == null ? '' : '（$detail）'}';
    }
    VirtualDisplayOverlayState.show();
    // 界面切换需要时间；这里只留很短的一点，避免读到动作前的帧。
    await Future<void>.delayed(const Duration(milliseconds: 180));
    final st = await d.vd.status();
    final after = await d.vd.fingerprint();
    // 指纹只回答一个问题：这一下点下去，界面到底变了没有。成本几毫秒。
    final changed = before.isNotEmpty && after.isNotEmpty && before != after;
    noProgress = changed ? 0 : noProgress + 1;
    final changeNote = changed ? '界面已变化' : '界面看起来没变（可能没点中，或还在加载）';

    if (noProgress >= 3) {
      // 别让它继续空转：连续三次界面没变，八成是屏没刷新 / 点错了 / 卡在弹窗上
      final st0 = await d.vd.status();
      sw.stop();
      return '$what 已下发，但**连续 $noProgress 次操作界面都没有任何变化**，看起来不是正常卡顿。\n'
          '先别继续点了，按这个顺序确认：\n'
          '1. vd_observe 看这页到底是什么（有没有弹窗、广告、需要登录）；\n'
          '2. 屏幕 ${st0.displayWidth ?? '?'}×${st0.displayHeight ?? '?'}，如果之前用的是坐标，改成 vd_tap 的 text / ref；\n'
          '3. 还不行就如实告诉用户"卡在哪一步、看到什么"，不要继续反复点。';
    }

    if (!st.accessibility) {
      // 无障碍没连时读屏只能走 OCR：每次动作后再读一遍要几百毫秒，点起来就很"卡"。
      // 所以这里不读文字，但**要把"变没变"告诉模型**——否则它点一下就以为完事了。
      sw.stop();
      return '$what 已下发（${sw.elapsedMilliseconds} ms，$changeNote）。'
          '无障碍没连，这次没读文字细节；要继续下一步就直接点/输入，需要看字再 vd_observe。';
    }
    // 动作后的读屏只取前 40 条：连续操作时上下文涨得最快的就是这些整屏 dump
    final text = await readScreen(maxElements: 40);
    sw.stop();
    final ms = sw.elapsedMilliseconds;
    final cost = ms < 1000 ? '$ms ms' : '${(ms / 1000).toStringAsFixed(1)} s';
    return '$what 已下发（$cost，$changeNote）。\n\n$text';
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
        if (!st.usable) {
          buf.write('\n（不用手动准备：任意 vd_* 工具都会自己建屏，只有缺 Shizuku 服务/授权时才需要你动手）');
        }
        if (st.shizukuDetail != null) buf.write('\nShizuku 细节：${st.shizukuDetail}');
        if (st.displayDetail != null) buf.write('\n虚拟屏细节：${st.displayDetail}');
        return buf.toString();
      },
    ),
    AppTool(
      name: 'vd_prepare',
      displayName: '重建虚拟屏（排障）',
      description:
          '正常情况**不需要调用**：其它 vd_* 工具都会自动建屏。'
          '只在屏卡住、画面不刷新、被系统回收后想强制重建时用它。',
      parameters: objectSchema({}),
      execute: (_) async {
        await d.vd.releaseDisplay();
        final off = await ensureReady(force: true);
        if (off != null) return off;
        final st = await d.vd.status();
        return '虚拟屏已重建（display=${st.displayId}）。'
            '${st.accessibility ? '' : '注意：无障碍没连，只能读 OCR 文字，不能按 ref 输入。'}';
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
          '这块虚拟屏没有系统导航栏（不显示手势条/三大金刚），回上一页一律用 vd_back，别去找按钮。'
          '需要看接口拿不到的行情（行业资金流、龙虎榜席位、F10 里没 API 的字段）时，'
          '用 vd_open 打开对应 App 读界面；能走 stock_kline / analyze_chan / stock_levels 的，优先走它们，不要开 App。',
      execute: (args) async {
        final raw = '${args['app'] ?? ''}'.trim();
        if (raw.isEmpty) return '需要给出 app（名字或包名）。';
        final off = await ensureReady();
        if (off != null) return '虚拟屏没准备好，打不开 App。$off';
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
        VirtualDisplayOverlayState.show();
        // 等界面真的有内容再回话：App 刚起时常是白屏/未挂载，这时读不到字。
        var text = await readScreen();
        for (var i = 0; i < 3 && _screenSeemsEmpty(text); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 800));
          text = await readScreen();
        }
        return '已在虚拟屏打开 $label（$pkg）。\n\n$text';
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
          '没开无障碍时自动退到本机 OCR，给「文字 + 坐标」。'
          '会自动建屏，不用先调准备。ref 只在这次读屏内有效，点击后要重新 observe。',
      parameters: objectSchema({'maxElements': intProp('最多返回多少个元素，默认 $kVirtualMaxElements')}),
      execute: (args) async {
        final off = await ensureReady();
        if (off != null) return off;
        final n = (args['maxElements'] as num?)?.toInt() ?? kVirtualMaxElements;
        return readScreen(maxElements: n, withImage: true, retryEmpty: true);
      },
    ),
    AppTool(
      name: 'vd_find',
      displayName: '在虚拟屏找元素',
      description: '在虚拟屏上按文字查元素，返回 ref。比 vd_observe 省 token，适合长列表（行情列表、公告、F10）。',
      parameters: objectSchema({'text': strProp('要匹配的文字')}, required: ['text']),
      execute: (args) async {
        final off = await ensureReady();
        if (off != null) return off;
        final st = await d.vd.status();
        final q = '${args['text'] ?? ''}'.trim().toLowerCase();
        if (q.isEmpty) return '需要 text。';
        final snap = await d.phone.observe(displayId: st.displayId);
        final all = (snap['elements'] as List?) ?? const [];
        final hits = snap['ok'] == true
            ? all.where((e) {
                final m = (e as Map);
                return '${m['name'] ?? ''}'.toLowerCase().contains(q) ||
                    '${m['resourceId'] ?? ''}'.toLowerCase().contains(q);
              }).toList()
            : const [];

        // 无障碍树里有就优先用它：带 ref，可点、可输入。
        if (hits.isNotEmpty) {
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
        }

        // 退到 OCR：没开无障碍时这是唯一能定位文字的路，结果是坐标。
        final lines = await d.vd.ocr();
        final ocrHits = lines.where((l) => '${l['text'] ?? ''}'.toLowerCase().contains(q)).toList();
        if (ocrHits.isNotEmpty) {
          final buf = StringBuffer('无障碍树没匹配到，但屏幕文字里找到 ${ocrHits.length} 行（OCR，点用坐标）：');
          for (final l in ocrHits.take(20)) {
            final c = (l['center'] as List?) ?? const [0, 0];
            buf.write('\n「${l['text']}」@${c[0]},${c[1]}');
          }
          buf.write('\n（要输入文字得先开无障碍服务，OCR 只能点不能打字）');
          return buf.toString();
        }

        final total = snap['ok'] == true ? '共 ${all.length} 个元素' : '无障碍没连';
        return '虚拟屏上没有匹配「${args['text']}」的内容（$total / ${lines.length} 行文字）。'
            '可能在下面，先 vd_scroll 再看。';
      },
    ),
    AppTool(
      name: 'vd_tap',
      displayName: '点虚拟屏',
      description:
          '点虚拟屏上的东西。三种给法，从稳到糙：'
          '① ref（observe/find 给的元素编号）；② text（要点的文字，自动在无障碍树和 OCR 结果里找）；'
          '③ x/y 坐标。动作后自动再读一次屏。',
      parameters: objectSchema({
        'ref': strProp('元素编号，如 @e12'),
        'text': strProp('要点的文字，如「自选股」「F10」「买入」；找不到会告诉你'),
        'x': intProp('X 坐标（虚拟屏像素）'),
        'y': intProp('Y 坐标（虚拟屏像素）'),
      }),
      promptHint:
          '这是**连续操作**：点开搜索框 → 输入代码 → 回车 → 看结果，一步一步接着做，'
          '直到用户要的最终状态出现再回话。不要点一下就停下来汇报进度。',
      execute: (args) async {
        final off = await ensureReady();
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
        // 按文字点：先无障碍树（准），没有再 OCR（只有文字行）
        final want = '${args['text'] ?? ''}'.trim().toLowerCase();
        if (want.isNotEmpty) {
          final snap = await d.phone.observe(displayId: st.displayId);
          for (final e in ((snap['elements'] as List?) ?? const [])) {
            final m = (e as Map);
            if ('${m['name'] ?? ''}'.toLowerCase().trim() != want) continue;
            final c = (m['center'] as List?) ?? const [0, 0];
            return actThenLook('点「${m['name']}」', () => d.vd.tap((c[0] as num).toInt(), (c[1] as num).toInt()));
          }
          final lines = await d.vd.ocr();
          final exact = lines.where((l) => '${l['text'] ?? ''}'.toLowerCase().trim() == want).toList();
          final fuzzy = lines.where((l) => '${l['text'] ?? ''}'.toLowerCase().contains(want)).toList();
          final pick = exact.isNotEmpty ? exact.first : (fuzzy.isNotEmpty ? fuzzy.first : null);
          if (pick == null) {
            return '虚拟屏上没有「${args['text']}」这个文字。先 vd_observe 看现在是什么界面。';
          }
          final c = (pick['center'] as List?) ?? const [0, 0];
          return actThenLook('点「${pick['text']}」', () => d.vd.tap((c[0] as num).toInt(), (c[1] as num).toInt()));
        }

        final x = (args['x'] as num?)?.toInt();
        final y = (args['y'] as num?)?.toInt();
        if (x == null || y == null) return '需要 ref，或者 text，或者 x 和 y。';
        // 坐标边界校验：把"按截图尺寸算"这种错挡在外面，而不是点在乱七八糟的地方
        final w = st.displayWidth;
        final h = st.displayHeight;
        if (w != null && h != null && (x < 0 || y < 0 || x >= w || y >= h)) {
          return '坐标 ($x,$y) 超出虚拟屏（$w×$h）。坐标按这块屏的像素给，'
              '或者直接用 ref / text 点——那样不用关心数值。';
        }
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
        final off = await ensureReady();
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
      description:
          '往虚拟屏写文字，三种给法：'
          '① ref（无障碍树里的输入框，最稳，支持中文）；'
          '② x/y（先点这个位置让输入框拿到焦点，再送文字）；'
          '③ 都不给（直接打进当前焦点）。'
          '②③ 走键盘事件、不需要无障碍，但只支持 ASCII（股票代码、英文、数字）；中文必须先开无障碍。'
          '**搜索框打完字通常要按回车才会真的搜**：这时传 enter=true，否则页面上什么都不会发生。',
      parameters: objectSchema(
        {
          'ref': strProp('输入框的 ref，如 @e12（要中文就必须走这个）'),
          'x': intProp('X 坐标：先点这里再输入'),
          'y': intProp('Y 坐标：先点这里再输入'),
          'text': strProp('要输入的文字'),
          'enter': strProp('true = 打完按回车（搜索框必须）', enumValues: ['true', 'false']),
        },
        required: ['text'],
      ),
      execute: (args) async {
        final off = await ensureReady();
        if (off != null) return off;
        final st = await d.vd.status();
        final text = '${args['text'] ?? ''}';
        if (text.isEmpty) return '需要 text。';
        final ref = '${args['ref'] ?? ''}'.trim();
        final wantEnter = '${args['enter'] ?? ''}' == 'true';

        /// 打完字之后统一收尾：要不要回车、等界面反应、读一次屏。
        Future<String> afterTyping(String msg) async {
          if (wantEnter) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
            await d.vd.pressKey('enter');
          }
          await Future<void>.delayed(const Duration(milliseconds: 400));
          return '$msg${wantEnter ? '，已按回车' : ''}。\n\n${await readScreen()}';
        }

        // ① 无障碍：能输入中文，先清空原内容
        if (ref.isNotEmpty) {
          final r = await d.phone.typeText(ref, text, displayId: st.displayId, clear: true);
          if (r['ok'] != true) return '输入失败：${r['error']}';
          return afterTyping('已输入「$text」');
        }

        // ②③ 键盘事件：不需要无障碍，但只有 ASCII
        final x = (args['x'] as num?)?.toInt();
        final y = (args['y'] as num?)?.toInt();
        if (x != null && y != null) {
          final tapped = await d.vd.tap(x, y);
          if (tapped['ok'] != true) return '点 ($x,$y) 没成功（${tapped['error'] ?? ''}），输入没做。';
          await Future<void>.delayed(const Duration(milliseconds: 350));
        }
        final r = await d.vd.asciiText(text);
        if (r['ok'] == true) return afterTyping('已输入「$text」');
        if (r['error'] == 'partial') {
          return '只送进去了前面一部分。先 vd_observe 看看框里现在是什么——**别重发**，会重复输入。';
        }
        final asciiOnly = text.runes.every((c) => c >= 0x20 && c <= 0x7e);
        return asciiOnly
            ? '键盘事件没送进去（${r['error'] ?? 'unknown'}）：先用 vd_tap 点一下输入框让它拿到焦点，再 vd_type。'
            : '这段文字含非 ASCII 字符（中文等），键盘事件送不了；要在虚拟屏打中文，得先把无障碍服务连上。';
      },
    ),
    AppTool(
      name: 'vd_back',
      displayName: '虚拟屏返回',
      description:
          '在这块虚拟屏上按系统键：key=back（默认）返回上一页，key=home 回桌面。'
          '**这块屏没有系统导航栏**（不像你手机那样有手势条/三大金刚），'
          '所以页面里找不到"返回"按钮时，返回就靠它——不要因为看不到按钮就停下来。',
      parameters: objectSchema({
        'key': strProp('back / home / recents', enumValues: ['back', 'home', 'recents']),
      }),
      promptHint:
          '虚拟屏上没有系统导航栏。要回上一页就调 vd_back（默认 back），不要去找页面上的返回按钮；'
          '连续操作时可以连着 vd_back 退到你要的那一层。',
      execute: (args) async {
        final off = await ensureReady();
        if (off != null) return off;
        final key = '${args['key'] ?? 'back'}';
        final st = await d.vd.status();
        final before = await d.vd.fingerprint();

        final r = await d.vd.pressKey(key);
        if (r['ok'] != true) return '按键没送进去：${r['error'] ?? r['message'] ?? 'unknown'}';
        await Future<void>.delayed(const Duration(milliseconds: 350));
        var after = await d.vd.fingerprint();
        final changed = before.isNotEmpty && after.isNotEmpty && before != after;

        if (key == 'back' && !changed) {
          // 有些自绘页面不吃 BACK 键。退回手机上的那套"从左边缘往里划"手势返回。
          final w = st.displayWidth;
          final h = st.displayHeight;
          if (w != null && h != null) {
            final y = (h * 0.5).round();
            await d.vd.swipe(2, y, (w * 0.35).round(), y, durationMs: 260);
            await Future<void>.delayed(const Duration(milliseconds: 400));
            after = await d.vd.fingerprint();
            if (after.isNotEmpty && after != before) {
              return '已返回（BACK 键没反应，改用了边缘手势）。\n\n${await readScreen()}';
            }
          }
          return '返回没生效：BACK 键和边缘手势都没让界面变化。这块屏没有系统导航栏，'
              '先 vd_observe 看看页面左上角有没有返回图标——有的话用 vd_tap text=「返回」点它。';
        }

        final text = await readScreen();
        final note = changed ? '' : '（界面没有变化，可能已经在最外层页面）';
        return '已按 $key$note。\n\n$text';
      },
    ),
  ];
}

/// 读屏结果是不是「什么都没有」（白屏、未挂载、纯图页），
/// 用来决定打开 App 后要不要再等一会儿重读。
bool _screenSeemsEmpty(String text) => text.contains('没有可读内容') || text.contains('还没出画面') || text.contains('有画面但没有文字');

/// 粗略判断是不是行情类 App（只用于默认过滤，不用于断定身份）。
bool _looksLikeMarket(String label) {
  const hints = ['同花顺', '通达信', '雪球', '开盘啦', '东方财富', '大智慧', '老虎', '富途', '股票', '证券', '行情', '炒股', '涨乐', '自选股', '韭研', '韭圈'];
  return hints.any(label.contains);
}

/// 把 OCR 结果渲染成给模型看的文本：每行带坐标，方便它直接点。
String renderOcrForModel(List<Map<String, dynamic>> ocrLines, {int maxElements = 80}) {
  if (ocrLines.isEmpty) return '（没有认出文字）';
  final buf = StringBuffer('屏幕文字（本机 OCR，共 ${ocrLines.length} 行）');
  if (ocrLines.length > maxElements) buf.write('，只列前 $maxElements 行');
  buf.writeln();
  var n = 0;
  for (final l in ocrLines) {
    if (n >= maxElements) break;
    final text = '${l['text'] ?? ''}'.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) continue;
    final c = (l['center'] as List?) ?? const [0, 0];
    buf.writeln('「$text」@${c[0]},${c[1]}');
    n++;
  }
  return buf.toString().trimRight();
}
