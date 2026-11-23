import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../agents/sub_agent_tools.dart';
import '../../agents/team_board.dart';
import '../../ai/message.dart';
import '../../core/i18n.dart';
import '../../core/util.dart';
import '../../tools/cartesian_plot.dart';
import '../../tools/spatial_plot.dart';
import '../widgets/cartesian_plot_view.dart';
import '../widgets/spatial_plot_view.dart';
import '../widgets/code_block.dart';
import '../widgets/motion.dart';

String toolLabel(String name) {
  if (name.startsWith('mcp__')) {
    final parts = name.split('__');
    return parts.length >= 3 ? '${parts[1]} · ${parts.sublist(2).join('__')}' : name;
  }
  return switch (name) {
    'search_web' => t('联网搜索', 'Web search'),
    'scrape_web' => t('读取网页', 'Read page'),
    'get_time_info' => t('获取时间', 'Get time'),
    'clipboard' => t('剪贴板', 'Clipboard'),
    'get_device_info' => t('设备信息', 'Device info'),
    'calculate' => t('计算器', 'Calculator'),
    'plot_cartesian' => t('平面直角坐标系', 'Cartesian plot'),
    'plot_spatial' => t('空间直角坐标系', '3D Cartesian plot'),
    'memory_save' => t('记住', 'Remember'),
    'memory_update' => t('更新记忆', 'Update memory'),
    'memory_delete' => t('删除记忆', 'Forget'),
    'web_search' => t('内置搜索', 'Built-in search'),
    'dispatch_subagents' => t('子智能体分派', 'Sub-agent dispatch'),
    'add_team_tasks' => t('追加团队任务', 'Add team tasks'),
    'discuss_subagents' => t('子智能体讨论', 'Sub-agent discussion'),
    _ => name,
  };
}

IconData toolIcon(String name) {
  if (name.startsWith('mcp__')) return Icons.extension_rounded;
  return switch (name) {
    'search_web' || 'web_search' || 'web_search_result' => Icons.travel_explore_rounded,
    'scrape_web' => Icons.article_outlined,
    'get_time_info' => Icons.schedule_rounded,
    'clipboard' => Icons.content_paste_rounded,
    'get_device_info' => Icons.smartphone_rounded,
    'calculate' => Icons.calculate_outlined,
    'http_request' => Icons.public_rounded,
    'workspace_read_file' || 'workspace_list_dir' => Icons.folder_open_rounded,
    'workspace_write_file' || 'workspace_edit_file' => Icons.edit_note_rounded,
    'plot_cartesian' || 'plot_spatial' => Icons.grid_on_rounded,
    'memory_save' || 'memory_update' || 'memory_delete' => Icons.bookmark_added_outlined,
    'dispatch_subagents' || 'discuss_subagents' => Icons.smart_toy_outlined,
    'add_team_tasks' => Icons.playlist_add_rounded,
    _ => Icons.build_circle_outlined,
  };
}

String _pretty(String s) {
  final j = tryJsonDecode(s);
  return j == null ? s : const JsonEncoder.withIndent('  ').convert(j);
}

class ToolCard extends StatefulWidget {
  const ToolCard({super.key, required this.part, this.onApprove, this.onDeny});
  final ToolPart part;
  final VoidCallback? onApprove;
  final VoidCallback? onDeny;

  @override
  State<ToolCard> createState() => _ToolCardState();
}

typedef _PlotResult = ({CartesianPlot? plane, SpatialPlot? space, String? error});
const _PlotResult _noPlot = (plane: null, space: null, error: null);

class _ToolCardState extends State<ToolCard> {
  bool _open = false;
  (String, String, bool)? _plotKey;
  _PlotResult _cachedPlot = _noPlot;

  // 子智能体分派在跑的时候，卡片自己按 400ms 刷新。
  // 只靠父级 rebuild 不够：聊天页在某些状态下不会频繁重建，卡片就"一点反应都没有"。
  Timer? _tick;

  bool get _liveTeam =>
      widget.part.output == null && (widget.part.name == 'dispatch_subagents' || widget.part.name == 'add_team_tasks');

  @override
  void initState() {
    super.initState();
    _syncTick();
  }

  @override
  void didUpdateWidget(covariant ToolCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTick();
  }

  void _syncTick() {
    if (_liveTeam) {
      _tick ??= Timer.periodic(const Duration(milliseconds: 400), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  _PlotResult _plotResult(ToolPart part) {
    final source = part.output;
    if (source == null ||
        part.approval == ToolApproval.denied ||
        (part.name != 'plot_cartesian' && part.name != 'plot_spatial')) {
      return _noPlot;
    }
    final key = (part.name, source, part.isError);
    if (_plotKey != key) {
      _plotKey = key;
      _cachedPlot = _decodePlot(part, source);
    }
    return _cachedPlot;
  }

  // Cache failures as well: rebuilding a malformed history entry must not
  // resurrect a previous plot or keep decoding the same payload while streaming.
  static _PlotResult _decodePlot(ToolPart part, String source) {
    try {
      final output = jsonDecode(source);
      if (output is! Map<String, dynamic>) return _noPlot;
      final error = output['error'];
      if (error != null) return (plane: null, space: null, error: error.toString());
      final json = output['plot'];
      if (part.isError || json is! Map<String, dynamic>) return _noPlot;
      return switch ((part.name, output['type'])) {
        ('plot_cartesian', 'cartesian_plot') => (plane: CartesianPlot.fromJson(json), space: null, error: null),
        ('plot_spatial', 'spatial_plot') => (plane: null, space: SpatialPlot.fromJson(json), error: null),
        _ => _noPlot,
      };
    } on FormatException {
      return _noPlot;
    } on TypeError {
      return _noPlot;
    }
  }

  String _summary() {
    final input = widget.part.inputJson;
    final v =
        input['title'] ??
        input['tool_title'] ??
        input['topic'] ??
        input['query'] ??
        input['url'] ??
        input['expression'] ??
        input['content'] ??
        input['action'];
    return v == null ? '' : truncate(v.toString(), 60);
  }

  Widget _leading(ColorScheme scheme, bool running) {
    final p = widget.part;
    if (running) {
      return SizedBox(
        key: const ValueKey('spin'),
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
      );
    }
    return Icon(
      p.isError ? Icons.error_outline_rounded : toolIcon(p.name),
      key: const ValueKey('icon'),
      size: 18,
      color: p.isError ? scheme.error : scheme.primary,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = widget.part;
    final running = !p.executed && p.approval != ToolApproval.pending;
    final summary = _summary();
    final (plane: plot, space: spatial, error: plotError) = _plotResult(p);
    final title = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: toolLabel(p.name),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (summary.isNotEmpty)
            TextSpan(
              text: '  $summary',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodyMedium,
    );
    final header = InkWell(
      onTap: () => setState(() => _open = !_open),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Row(
          children: [
            AnimatedSwitcher(duration: const Duration(milliseconds: 250), child: _leading(scheme, running)),
            const SizedBox(width: 10),
            Flexible(child: title),
            const SizedBox(width: 6),
            AnimatedRotation(
              turns: _open ? 0.5 : 0,
              duration: const Duration(milliseconds: 250),
              child: Icon(Icons.expand_more_rounded, size: 20, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
    late final details = Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CodeBlock(code: _pretty(p.input), language: 'json', wrap: true),
          if (p.output != null) CodeBlock(code: _pretty(p.output!), language: 'json', wrap: true),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: running ? 0.08 : 0.05),
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.antiAlias,
        // Ink is painted on the nearest Material. Without one inside the
        // clip it landed on the page below the card and showed up as a grey
        // rectangle around the rounded corners.
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              _SubAgentTrace(part: p),
              if (plotError != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Text(plotError, style: TextStyle(color: scheme.error)),
                ),
              if (plot != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                  child: CartesianPlotCard(
                    key: ValueKey('plot-${p.callId}-${p.output}'),
                    plot: plot,
                    showHeader: false,
                  ),
                ),
              if (spatial != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                  child: SpatialPlotCard(
                    key: ValueKey('spatial-${p.callId}-${p.output}'),
                    plot: spatial,
                    showHeader: false,
                  ),
                ),
              if (p.pending) _approvalBar(context),
              AnimatedSize(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _open ? details : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _approvalBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return EntranceFx(
      dy: 6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 10, 10),
        child: Row(
          children: [
            Icon(Icons.shield_outlined, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
            Expanded(child: Text(t('允许运行这个工具吗？', 'Allow this tool to run?'), style: style)),
            TextButton(onPressed: widget.onDeny, child: Text(t('拒绝', 'Deny'))),
            const SizedBox(width: 4),
            FilledButton.tonal(onPressed: widget.onApprove, child: Text(t('允许', 'Allow'))),
          ],
        ),
      ),
    );
  }
}

class CitationChips extends StatelessWidget {
  const CitationChips({super.key, required this.items});
  final List<Citation> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var i = 0; i < items.length && i < 12; i++)
            EntranceFx(
              index: i,
              dy: 6,
              child: _CitationChip(index: i, item: items[i]),
            ),
        ],
      ),
    );
  }
}

class _CitationChip extends StatelessWidget {
  const _CitationChip({required this.index, required this.item});
  final int index;
  final Citation item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = item.title.isEmpty ? (Uri.tryParse(item.url)?.host ?? item.url) : item.title;
    return Pressable(
      onTap: () => launchUrl(Uri.parse(item.url), mode: LaunchMode.externalApplication),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 220),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(10)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 18,
              height: 18,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.15), shape: BoxShape.circle),
              child: Text(
                '${index + 1}',
                style: TextStyle(fontSize: 10, color: scheme.primary, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分派 / 追加 / 讨论三个工具在聊天流里的实时视图。
///
/// 关键改动：优先读 `meta['board']`——这是 dispatch 运行期一路推上来的任务板快照，
/// 所以任务还在跑的时候，卡片里就能看到「运行中 / 等待前置」和依赖关系，
/// 而不是等整个分派结束才蹦出一段 JSON。
class _SubAgentTrace extends StatelessWidget {
  const _SubAgentTrace({required this.part});

  final ToolPart part;

  static const _names = {'dispatch_subagents', 'add_team_tasks', 'discuss_subagents'};

  bool get _isSubAgent => _names.contains(part.name);

  /// 实时任务板：优先 meta.board，退回已完成 output 里的 board。
  Map<String, dynamic>? get _board {
    // 还没返回的分派：直接读内存里那张活的任务板。
    // meta.board 是序列化快照，万一那步没写进去，界面就永远空白——这里兜住。
    if (part.output == null) {
      final live = activeTeamBoard;
      if (live != null && live.tasks.isNotEmpty) return live.toJson();
    }
    final meta = part.meta?['board'];
    if (meta is Map) {
      final m = asMap(meta);
      if (m['tasks'] is List) return m;
    }
    final raw = part.output;
    if (raw == null) return null;
    final j = tryJsonDecode(raw);
    if (j is! Map) return null;
    final b = asMap(j)['board'];
    if (b is Map && asMap(b)['tasks'] is List) return asMap(b);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (!_isSubAgent) return const SizedBox.shrink();
    final board = _board;
    if (board != null) return _buildBoard(context, board);
    return _buildLegacy(context);
  }

  // ------------------------------------------------------------ 任务板视图

  Widget _buildBoard(BuildContext context, Map<String, dynamic> board) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final tasks = board['tasks'] is List
        ? [
            for (final e in (board['tasks'] as List))
              if (e is Map) asMap(e),
          ]
        : const <Map<String, dynamic>>[];
    if (tasks.isEmpty) return const SizedBox.shrink();
    final running = (board['running'] is num ? (board['running'] as num).toInt() : 0);
    final pending = (board['pending'] is num ? (board['pending'] as num).toInt() : 0);
    final title = asStr(board['title']).trim();
    final tokIn = (board['tokens_in'] is num ? (board['tokens_in'] as num).toInt() : 0);
    final tokOut = (board['tokens_out'] is num ? (board['tokens_out'] as num).toInt() : 0);
    final ms = (board['elapsed_ms'] is num ? (board['elapsed_ms'] as num).toInt() : 0);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(title, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            ),
          for (final row in tasks) _taskRow(context, row),
          if (running > 0 || pending > 0 || tokIn > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (running > 0) _badge(context, t('$running 个运行中', '$running running'), scheme.primary),
                  if (pending > 0) _badge(context, t('$pending 个等待前置', '$pending waiting'), scheme.outline),
                  if (tokIn > 0)
                    Text(
                      '↑${formatTokens(tokIn)} ↓${formatTokens(tokOut)}'
                      '${ms > 0 ? ' · ${formatDuration(ms)}' : ''}',
                      style: style,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _taskRow(BuildContext context, Map<String, dynamic> row) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final status = asStr(row['status']);
    final deps = row['depends_on'] is List
        ? [for (final d in (row['depends_on'] as List)) asStr(d)].where((e) => e.isNotEmpty).toList()
        : const <String>[];
    final text = asStr(row['task']).replaceAll('\n', ' ').trim();
    final short = text.length <= 56 ? text : '${text.substring(0, 56)}…';
    final running = status == 'running';
    final rawOutput = asStr(row['output']).trim();
    final liveText = running ? rawOutput.replaceAll(RegExp(r'\s+'), ' ') : '';
    // 已完成的产出也直接铺在卡片上（最多三行）：不想为了看结论再点开面板。
    final doneText = !running ? rawOutput.replaceAll(RegExp(r'\s+'), ' ') : '';
    final steps = row['steps'];
    final stepLines = <String>[];
    if (steps is List) {
      // 协作类（问主控 / 问同伴 / 申请工具）优先露脸：它们说明"它卡在哪、怎么解的"，
      // 比再列一条 http_request 有用。剩下的位置再补普通步骤。
      const collab = {'ask_main_agent', 'ask_peer', 'request_capability'};
      final parsed = <Map<String, dynamic>>[
        for (final e in steps)
          if (e is Map) asMap(e),
      ];
      // 优先级：推理（最能说明它在想什么）> 协作调用 > 普通工具。
      for (final m in parsed.reversed) {
        if (asStr(m['type']) != 'reasoning') continue;
        final text = asStr(m['output']).replaceAll(RegExp(r'\s+'), ' ').trim();
        if (text.isEmpty) continue;
        stepLines.insert(0, '· ${t('思考', 'thinking')} ${text.length <= 40 ? text : '${text.substring(0, 40)}…'}');
        if (stepLines.length >= 2) break;
      }
      if (stepLines.length < 2) {
        for (final m in parsed.reversed) {
          final tool = asStr(m['tool']);
          if (!collab.contains(tool)) continue;
          stepLines.insert(0, _collabLine(tool, m));
          if (stepLines.length >= 2) break;
        }
      }
      if (stepLines.length < 2) {
        for (final m in parsed.reversed) {
          final tool = asStr(m['tool']);
          if (tool.isEmpty || collab.contains(tool) || asStr(m['type']) != 'tool') continue;
          final ok = m['ok'] == true;
          final ms = m['ms'] is num ? (m['ms'] as num).toInt() : 0;
          stepLines.insert(0, '· $tool ${ok ? '✓' : '✗'}${ms > 0 ? ' ${ms}ms' : ''}');
          if (stepLines.length >= 2) break;
        }
      }
    }
    final color = switch (status) {
      'running' => scheme.primary,
      'done' => scheme.tertiary,
      'failed' => scheme.error,
      _ => scheme.outline,
    };

    final icon = running
        ? SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.8, color: color))
        : Icon(
            switch (status) {
              'done' => Icons.check_circle_outline_rounded,
              'failed' => Icons.error_outline_rounded,
              'skipped' => Icons.remove_circle_outline_rounded,
              _ => Icons.radio_button_unchecked,
            },
            size: 14,
            color: color,
          );

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: running ? scheme.primaryContainer.withValues(alpha: 0.45) : null,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: icon),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(short, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(height: 1.3)),
                Text(
                  [
                    asStr(row['id']),
                    asStr(row['agent']),
                    if (row['ms'] is num && (row['ms'] as num) > 0) formatDuration((row['ms'] as num).toInt()),
                  ].join(' · '),
                  style: style,
                ),
                if (deps.isNotEmpty) Text('${t('依赖', 'depends on')}：${deps.join('、')}', style: style),
                // 实时内容：它在写什么（逐段刷新，最多两行）
                if (liveText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      liveText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: style?.copyWith(color: scheme.onSurface, height: 1.35),
                    ),
                  ),
                // 已完成：结论摘要
                if (doneText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      doneText,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: style?.copyWith(color: scheme.onSurface, height: 1.35),
                    ),
                  ),
                // 已经跑过的工具步骤（只看最后两条，完整列表在展开区）
                if (stepLines.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(stepLines.join('\n'), maxLines: 2, overflow: TextOverflow.ellipsis, style: style),
                  ),
                if (asStr(row['error']).isNotEmpty)
                  Text(
                    asStr(row['error']),
                    style: style?.copyWith(color: scheme.error),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          _badge(context, _statusWord(status), color),
          if (running && asStr(row['run_key']).isNotEmpty) ...[
            const SizedBox(width: 2),
            // 单独终止：只停这一条子任务，同批其他任务继续跑。
            IconButton(
              tooltip: t('终止', 'Stop'),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              icon: Icon(Icons.stop_circle_outlined, size: 18, color: scheme.error),
              onPressed: () => cancelTeamTask(asStr(row['run_key'])),
            ),
          ],
        ],
      ),
    );
  }

  /// 协作类步骤显示成一句人话。
  String _collabLine(String tool, Map<String, dynamic> m) {
    final raw = asStr(m['output']);
    final ok = m['ok'] == true;
    final j = tryJsonDecode(raw);
    String detail = '';
    if (j is Map) {
      final mm = asMap(j);
      for (final k in const ['answer', 'output', 'note', 'error']) {
        final v = asStr(mm[k]).replaceAll(RegExp(r'\s+'), ' ').trim();
        if (v.isNotEmpty) {
          detail = v.length <= 40 ? v : '${v.substring(0, 40)}…';
          break;
        }
      }
    }
    if (detail.isEmpty) {
      detail = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    final label = switch (tool) {
      'ask_main_agent' => t('问主控', 'asked lead'),
      'ask_peer' => t('问同伴', 'asked peer'),
      'request_capability' => t('申请工具', 'requested tool'),
      _ => tool,
    };
    return '· $label ${ok ? '✓' : '✗'}${detail.isEmpty ? '' : ' $detail'}';
  }

  String _statusWord(String s) => switch (s) {
    'running' => t('运行中', 'running'),
    'pending' => t('等待前置', 'waiting'),
    'done' => t('已完成', 'done'),
    'failed' => t('失败', 'failed'),
    'skipped' => t('已跳过', 'skipped'),
    _ => s,
  };

  Widget _badge(BuildContext context, String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
    child: Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
  );

  // ------------------------------------------------------------ 旧视图兜底

  Widget _buildLegacy(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final progress = [
      for (final e in (part.meta?['progress'] as List?) ?? const [])
        if (e is String && e.trim().isNotEmpty) e,
    ];
    final rows = _rows();
    if (progress.isEmpty && rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in progress) Text('· $line', style: style),
          if (rows.isNotEmpty && progress.isNotEmpty) const SizedBox(height: 6),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    r.ok ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
                    size: 14,
                    color: r.ok ? scheme.primary : scheme.error,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: r.label,
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              if (r.detail.isNotEmpty)
                                TextSpan(
                                  text: '  ${r.detail}',
                                  style: TextStyle(color: scheme.onSurfaceVariant),
                                ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (r.text.isNotEmpty) Text(r.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: style),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<_SubAgentRow> _rows() {
    final raw = part.output;
    if (raw == null) return const [];
    final j = tryJsonDecode(raw);
    if (j is! Map) return const [];
    final out = <_SubAgentRow>[];
    final results = j['results'];
    if (results is List) {
      for (final e in results) {
        if (e is! Map) continue;
        out.add(
          _SubAgentRow(
            label: asStr(e['agent']),
            ok: e['ok'] == true,
            detail: _detail(asMap(e)),
            text: asStr(e['output']),
          ),
        );
      }
    }
    final turns = j['turns'];
    if (turns is List) {
      for (final e in turns) {
        if (e is! Map) continue;
        out.add(
          _SubAgentRow(
            label: '${t('第', 'Round')} ${e['round']} · ${asStr(e['agent'])}',
            ok: e['ok'] == true,
            detail: _detail(asMap(e)),
            text: asStr(e['output']),
          ),
        );
      }
    }
    return out;
  }

  String _detail(Map<String, dynamic> e) {
    final steps = e['steps'];
    final n = steps is List ? steps.length : 0;
    final ms = e['ms'] is num ? (e['ms'] as num).toInt() : 0;
    final tokens = e['tokens'];
    var tok = 0;
    if (tokens is Map) {
      final i = tokens['input'];
      final o = tokens['output'];
      tok = (i is num ? i.toInt() : 0) + (o is num ? o.toInt() : 0);
    }
    final bits = <String>[
      if (n > 0) '$n ${t('步', 'steps')}',
      if (tok > 0) formatTokens(tok),
      if (ms > 0) formatDuration(ms),
    ];
    return bits.join(' · ');
  }
}

class _SubAgentRow {
  const _SubAgentRow({required this.label, required this.ok, required this.detail, required this.text});
  final String label;
  final bool ok;
  final String detail;
  final String text;
}
