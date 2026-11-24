import 'package:flutter/material.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/tools/virtual_display_channel.dart';
import 'package:mewhub/ui/widgets/common.dart';

/// 虚拟屏（手机操控）设置页。
///
/// 这里只做一件事：**把"还差哪一步"说清楚**，并给出那一步的按钮。
/// 状态来自 [VirtualDisplayChannel.status]，每次进入页面刷新一次。
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

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
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
      _message = r['ok'] == true ? okText : '${r['error'] ?? '失败'}${r['detail'] == null ? '' : '：${r['detail']}'}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final st = _status;
    return Scaffold(
      appBar: AppBar(title: Text(t('虚拟屏', 'Virtual display'))),
      body: ListView(
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
                    '虚拟屏在后台运行 App，不占用你的主屏。需要 Shizuku 或无线调试配对。',
                    'Runs apps on a hidden display. Needs Shizuku or wireless-debugging pairing.',
                  ),
                ),
              ),
              if (_message != null) ListTile(leading: const IconBadge(Icons.message_rounded), title: Text(_message!)),
            ],
          ),
          if (st != null && !st.usable) ...[
            SettingsGroup(
              title: t('路线 1：Shizuku', 'Route 1: Shizuku'),
              footer: Text(t('装好 Shizuku 并启动服务后，在这里点一次授权即可。', 'Install and start Shizuku, then grant once here.')),
              children: [
                ListTile(
                  leading: const IconBadge(Icons.extension_rounded),
                  title: Text(t('Shizuku 状态', 'Shizuku status')),
                  subtitle: Text(_shizukuLabel(st)),
                  trailing: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : null,
                ),
                ListTile(
                  leading: const IconBadge(Icons.launch_rounded),
                  title: Text(t('打开 Shizuku', 'Open Shizuku')),
                  onTap: () async {
                    await _ch.openShizuku();
                    await _refresh();
                  },
                ),
                ListTile(
                  leading: const IconBadge(Icons.key_rounded),
                  title: Text(t('请求授权', 'Request permission')),
                  onTap: () => _run(_ch.requestPermission, t('已弹出授权请求', 'Permission requested')),
                ),
                ListTile(
                  leading: const IconBadge(Icons.layers_rounded),
                  title: Text(t('准备虚拟屏', 'Prepare display')),
                  onTap: () => _run(_ch.ensureDisplay, t('虚拟屏已就绪', 'Display ready')),
                ),
              ],
            ),
            SettingsGroup(
              title: t('路线 2：无线调试', 'Route 2: Wireless debugging'),
              footer: Text(
                t(
                  '系统设置 → 开发者选项 → 无线调试 → 使用配对码配对设备，抄下 6 位码（对话框别关），填在这里。',
                  'Settings → Developer options → Wireless debugging → Pair device with pairing code; copy the 6-digit code.',
                ),
              ),
              children: [
                ListTile(
                  leading: const IconBadge(Icons.wifi_tethering_rounded),
                  title: Text(t('配对状态', 'Pairing status')),
                  subtitle: Text('${st.wireless}${st.wirelessDetail == null ? '' : '：${st.wirelessDetail}'}'),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _codeCtl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: t('6 位配对码', '6-digit code'),
                            isDense: true,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _busy
                            ? null
                            : () => _run(() => _ch.pairWireless(_codeCtl.text), t('配对成功，可以点下一步了', 'Paired')),
                        child: Text(t('配对', 'Pair')),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  leading: const IconBadge(Icons.play_arrow_rounded),
                  title: Text(t('启动助手', 'Start helper')),
                  subtitle: Text(t('配对成功后点这里，让 App 以 shell 身份起助手', 'After pairing, start the shell helper')),
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
                        : t('无障碍未连接：读不到文字，只能截图', 'Accessibility off: text unreadable'),
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
    );
  }

  String _shizukuLabel(VirtualDisplayStatus st) => switch (st.shizuku) {
    'not_installed' => t('没装 Shizuku', 'Shizuku not installed'),
    'not_running' => t('装了但服务没运行', 'Installed but not running'),
    'need_permission' => t('需要授权', 'Permission needed'),
    'binding' => t('正在绑定…', 'Binding…'),
    'ready' => t('已连接', 'Connected'),
    'failed' => '${st.shizukuDetail ?? '失败'}',
    _ => st.shizuku,
  };
}
