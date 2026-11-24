import 'package:flutter/material.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/tools/virtual_display_channel.dart';
import 'package:mewhub/ui/widgets/common.dart';

/// 虚拟屏（手机操控）设置页。
///
/// 设计目标：**每一步都说清"现在缺什么、你要做什么"**。
/// 两条路（Shizuku / 无线调试）的步骤、失败原因都直接摆出来，不做成需要猜的形式。
class VirtualDisplayPage extends StatefulWidget {
  const VirtualDisplayPage({super.key, this.channel});

  final VirtualDisplayChannel? channel;

  @override
  State<VirtualDisplayPage> createState() => _VirtualDisplayPageState();
}

class _VirtualDisplayPageState extends State<VirtualDisplayPage> {
  late final VirtualDisplayChannel _ch = widget.channel ?? VirtualDisplayChannel();
  VirtualDisplayStatus? _status;
  bool _busy = false;
  String? _message;
  final _codeCtl = TextEditingController();
  bool _pairing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    if (_pairing) _ch.endPairing();
    _codeCtl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final st = await _ch.status();
    if (!mounted) return;
    setState(() => _status = st);
  }

  Future<void> _run(Future<Map<String, dynamic>> Function() action, String okText) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final r = await action();
    await _refresh();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = r['ok'] == true
          ? (r['note']?.toString() ?? okText)
          : '${r['error'] ?? '失败'}${r['detail'] == null ? '' : '：${r['detail']}'}';
    });
  }

  /// 开始配对：先让原生把通知栏输入框放出来，再引导用户去开配对对话框。
  Future<void> _beginPairing() async {
    final r = await _ch.beginPairing();
    if (!mounted) return;
    setState(() {
      _pairing = r['ok'] == true;
      _message = r['note']?.toString() ?? '已开始配对';
    });
    // 顺手打开无线调试页，省得用户自己找
    await _ch.openWirelessSettings();
  }

  @override
  Widget build(BuildContext context) {
    final st = _status;
    return Scaffold(
      appBar: AppBar(
        title: Text(t('虚拟屏', 'Virtual display')),
        actions: [
          IconButton(tooltip: t('刷新', 'Refresh'), onPressed: _refresh, icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 40),
          children: [
            SettingsGroup(
              title: t('现在能不能用', 'Availability'),
              children: [
                ListTile(
                  leading: IconBadge(
                    st?.usable == true ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                    color: st?.usable == true ? Colors.green : null,
                  ),
                  title: Text(st == null ? t('读取中…', 'Reading…') : st.describe()),
                  subtitle: Text(
                    t(
                      '虚拟屏在后台运行 App，不占用你的主屏。Shizuku 或无线调试，任一条通就行。',
                      'Runs apps on a hidden display. Either Shizuku or wireless debugging works.',
                    ),
                  ),
                ),
                if (_message != null)
                  ListTile(leading: const IconBadge(Icons.chat_bubble_outline_rounded), title: Text(_message!)),
              ],
            ),
            if (st != null && !st.usable) ...[
              // ---------------- 路线 1 ----------------
              SettingsGroup(
                title: t('路线 1 · Shizuku', 'Route 1 · Shizuku'),
                footer: t(
                  '两步：启动 Shizuku 服务 → 给问股授权。'
                      '之后 AI 用虚拟屏时会**自己建屏**，不用再手动准备；'
                      '下面的「建屏」按钮只在屏卡住时排障用。'
                      '装过 Shizuku 但重装了问股的话，要在这里重新授权一次（授权是按 uid 记的）。',
                  'Start Shizuku → grant this app. The AI builds the display itself; '
                      'the button below is only for troubleshooting.',
                ),
                children: [
                  ListTile(
                    leading: IconBadge(
                      st.shizukuReady ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                      color: st.shizukuReady ? Colors.green : null,
                    ),
                    title: Text(t('服务', 'Service')),
                    subtitle: Text(
                      st.shizukuRunning ? t('正在运行', 'Running') : t('没在运行 —— 打开 Shizuku 点「启动服务」', 'Not running'),
                    ),
                  ),
                  ListTile(
                    leading: IconBadge(
                      st.shizukuGranted ? Icons.check_circle_rounded : Icons.key_off_rounded,
                      color: st.shizukuGranted ? Colors.green : null,
                    ),
                    title: Text(t('授权', 'Permission')),
                    subtitle: Text(st.shizukuGranted ? t('已授权', 'Granted') : t('未授权 —— 点下面「请求授权」', 'Not granted')),
                  ),
                  ListTile(
                    leading: const IconBadge(Icons.launch_rounded),
                    title: Text(t('1. 打开 Shizuku', '1. Open Shizuku')),
                    subtitle: Text(t('去启动服务', 'Start the service there')),
                    onTap: () async {
                      await _ch.openShizuku();
                      await _refresh();
                    },
                  ),
                  ListTile(
                    leading: const IconBadge(Icons.key_rounded),
                    title: Text(t('2. 请求授权', '2. Request permission')),
                    onTap: () => _run(_ch.requestPermission, t('已弹出授权请求', 'Permission requested')),
                  ),
                  ListTile(
                    leading: const IconBadge(Icons.layers_rounded),
                    title: Text(t('建屏（排障用）', 'Build display (troubleshooting)')),
                    onTap: () => _run(_ch.ensureDisplay, t('虚拟屏已就绪', 'Display ready')),
                  ),
                ],
              ),
              // ---------------- 路线 2 ----------------
              SettingsGroup(
                title: t('路线 2 · 无线调试', 'Route 2 · Wireless debugging'),
                footer: t(
                  '点「开始配对」之后，通知栏会先出现「输入配对码」。'
                      '然后去系统设置开配对对话框——那个窗口不用关，'
                      '无障碍开着的话我会自己把码读走；读不到你就下拉通知栏直接填。',
                  'Start pairing first (a notification with an input box appears), '
                      'then open the pairing dialog in system settings. It never has to be closed.',
                ),
                children: [
                  ListTile(
                    leading: IconBadge(
                      st.wirelessReady ? Icons.check_circle_rounded : Icons.wifi_tethering_rounded,
                      color: st.wirelessReady ? Colors.green : null,
                    ),
                    title: Text(t('配对状态', 'Pairing')),
                    subtitle: Text('${st.wireless}${st.wirelessDetail == null ? '' : '：${st.wirelessDetail}'}'),
                  ),
                  ListTile(
                    leading: const IconBadge(Icons.notifications_active_rounded),
                    title: Text(
                      _pairing ? t('正在配对…（看通知栏）', 'Pairing… check the notification') : t('开始配对', 'Start pairing'),
                    ),
                    subtitle: Text(t('先放通知，再去开系统配对对话框', 'Puts the input box in the notification first')),
                    onTap: _busy ? null : _beginPairing,
                  ),
                  ListTile(
                    leading: const IconBadge(Icons.settings_rounded),
                    title: Text(t('打开无线调试页面', 'Open wireless debugging')),
                    onTap: () => _ch.openWirelessSettings(),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _codeCtl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: t('也可以在这里填 6 位码', 'Or type the 6-digit code here'),
                              isDense: true,
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _busy
                              ? null
                              : () => _run(() => _ch.pairWireless(_codeCtl.text), t('配对成功', 'Paired')),
                          child: Text(t('配对', 'Pair')),
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    leading: const IconBadge(Icons.play_arrow_rounded),
                    title: Text(t('启动助手', 'Start helper')),
                    subtitle: Text(t('配对成功后点这里', 'After pairing')),
                    onTap: () => _run(_ch.startWireless, t('助手已启动', 'Helper started')),
                  ),
                  ListTile(
                    leading: const IconBadge(Icons.link_off_rounded),
                    title: Text(t('解除配对', 'Forget pairing')),
                    onTap: () => _run(_ch.forgetWireless, t('已解除', 'Forgotten')),
                  ),
                ],
              ),
            ],
            if (st?.usable == true)
              SettingsGroup(
                title: t('已就绪', 'Ready'),
                children: [
                  ListTile(
                    leading: const IconBadge(Icons.memory_rounded),
                    title: Text(t('虚拟屏 display=${st!.displayId}', 'Display id ${st.displayId}')),
                    subtitle: Text(
                      st.accessibility
                          ? t('无障碍已连接，能读到界面文字', 'Accessibility connected')
                          : t('无障碍未连接：读不到文字，只能截图', 'Accessibility off'),
                    ),
                  ),
                  ListTile(
                    leading: const IconBadge(Icons.restart_alt_rounded),
                    title: Text(t('重建虚拟屏', 'Recreate display')),
                    onTap: () => _run(() async {
                      await _ch.releaseDisplay();
                      return _ch.ensureDisplay();
                    }, t('已重建', 'Recreated')),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
