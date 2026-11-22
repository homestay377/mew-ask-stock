import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/paths.dart';
import 'tool.dart';

/// 受控的工作区文件工具。
///
/// 对齐清水 1.4.2 的 `workspace_*` 家族：子智能体要真能干活，至少要有
/// 「读文件 / 写文件 / 改文件」三件套。这里不提供 shell（见 [workspaceShellTool] 的说明），
/// 所有路径都会被归一化后限制在允许的根目录内，越界直接拒绝。
const workspaceReadFileTool = 'workspace_read_file';
const workspaceWriteFileTool = 'workspace_write_file';
const workspaceEditFileTool = 'workspace_edit_file';
const workspaceListDirTool = 'workspace_list_dir';

/// 写类工具：只读子智能体要屏蔽掉这些。
const workspaceWriteTools = <String>{workspaceWriteFileTool, workspaceEditFileTool};

/// 单次读文件最多返回的字节数，避免把上下文撑爆。
const _readLimit = 64 * 1024;

/// 允许访问的根目录。顺序即提示顺序。
List<String> workspaceRoots() {
  final roots = <String>[AppPaths.support.path];
  if (Platform.isAndroid) {
    roots.add('/storage/emulated/0');
    roots.add('/data/local/tmp');
  }
  if (Platform.isIOS) {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) roots.add(home);
  }
  roots.add(Directory.systemTemp.path);
  return roots;
}

/// 把用户给的路径解析成绝对路径；相对路径相对 [AppPaths.support]。
String resolveWorkspacePath(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return '';
  if (t.startsWith('~')) {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) return p.normalize(p.join(home, t.substring(1)));
  }
  if (p.isAbsolute(t)) return p.normalize(t);
  return p.normalize(p.join(AppPaths.support.path, t));
}

/// 是否在允许的根目录内。
bool isInsideWorkspace(String abs, {bool allowTemp = true}) {
  if (abs.isEmpty) return false;
  for (final root in workspaceRoots()) {
    if (!allowTemp && root == Directory.systemTemp.path) continue;
    if (abs == root) return true;
    if (abs.startsWith('$root/')) return true;
    if (abs.startsWith('$root${Platform.pathSeparator}')) return true;
  }
  return false;
}

/// 统一的前置校验：返回 null 表示通过，否则返回错误 JSON。
String? _guard(String raw) {
  final abs = resolveWorkspacePath(raw);
  if (abs.isEmpty) return jsonEncode({'error': 'path 不能为空'});
  if (!isInsideWorkspace(abs)) {
    return jsonEncode({'error': '路径不在允许范围内', 'path': abs, 'allowed_roots': workspaceRoots()});
  }
  return null;
}

AppTool buildWorkspaceReadFileTool() => AppTool(
  name: workspaceReadFileTool,
  displayName: '读取文件',
  description:
      '读取一个文本文件的内容。支持指定起始行与最大行数；'
      '超过 $_readLimit 字节会自动截断并提示。二进制文件会返回错误与大小。',
  parameters: objectSchema(
    {
      'path': strProp('文件路径。相对路径以应用支持目录为基准，也可以给 /sdcard/... 这样的绝对路径'),
      'start_line': intProp('从第几行开始读（1 起），默认 1'),
      'max_lines': intProp('最多读多少行，默认 200，上限 2000'),
    },
    required: ['path'],
  ),
  promptHint: '读文件前先确认路径存在；读不到就明确说读不到，不要猜内容。',
  execute: (args) async {
    final bad = _guard(str(args['path']));
    if (bad != null) return bad;
    final abs = resolveWorkspacePath(str(args['path']));
    final f = File(abs);
    if (!await f.exists()) {
      return jsonEncode({'error': '文件不存在', 'path': abs});
    }
    final stat = await f.stat();
    if (stat.type != FileSystemEntityType.file) {
      return jsonEncode({'error': '不是一个文件', 'path': abs, 'type': _entityTypeName(stat.type)});
    }
    final raf = await f.open();
    try {
      final take = stat.size > _readLimit ? _readLimit : stat.size;
      final bytes = await raf.read(take);
      if (bytes.contains(0)) {
        return jsonEncode({'error': '看起来是二进制文件，没有返回内容', 'path': abs, 'bytes': stat.size});
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      final all = const LineSplitter().convert(text);
      final start = ((args['start_line'] is int ? args['start_line'] as int : 1) - 1).clamp(0, all.length);
      final maxLines = (args['max_lines'] is int ? args['max_lines'] as int : 200).clamp(1, 2000);
      final slice = all.skip(start).take(maxLines).toList();
      final lines = <String>[];
      for (var i = 0; i < slice.length; i++) {
        lines.add('${start + i + 1}\t${slice[i]}');
      }
      return jsonEncode({
        'ok': true,
        'path': abs,
        'bytes': stat.size,
        'total_lines': all.length,
        'from': start + 1,
        'to': start + slice.length,
        'truncated': stat.size > _readLimit,
        'content': lines.join('\n'),
      });
    } finally {
      await raf.close();
    }
  },
);

AppTool buildWorkspaceWriteFileTool() => AppTool(
  name: workspaceWriteFileTool,
  displayName: '写入文件',
  description: '把文本写入文件。会创建父目录；append=true 时追加而不是覆盖。',
  parameters: objectSchema(
    {
      'path': strProp('目标文件路径'),
      'content': strProp('要写入的完整文本'),
      'append': {'type': 'boolean', 'description': '是否追加到文件末尾，默认 false（覆盖）'},
    },
    required: ['path', 'content'],
  ),
  execute: (args) async {
    final bad = _guard(str(args['path']));
    if (bad != null) return bad;
    final abs = resolveWorkspacePath(str(args['path']));
    final content = args['content'] is String ? args['content'] as String : jsonEncode(args['content']);
    final append = args['append'] == true;
    try {
      final f = File(abs);
      await f.parent.create(recursive: true);
      await f.writeAsString(content, mode: append ? FileMode.append : FileMode.write, flush: true);
      final size = await f.length();
      return jsonEncode({'ok': true, 'path': abs, 'bytes': size, 'appended': append, 'chars_written': content.length});
    } on Object catch (e) {
      return jsonEncode({'error': '$e', 'path': abs});
    }
  },
);

AppTool buildWorkspaceEditFileTool() => AppTool(
  name: workspaceEditFileTool,
  displayName: '编辑文件',
  description:
      '在文件中把 old_text 替换成 new_text。默认要求 old_text 唯一匹配，'
      '匹配不到或不唯一都会失败并提示；replace_all=true 时替换全部。',
  parameters: objectSchema(
    {
      'path': strProp('目标文件路径'),
      'old_text': strProp('要被替换的原文，必须和文件内容完全一致'),
      'new_text': strProp('替换成的内容；空字符串表示删除'),
      'replace_all': {'type': 'boolean', 'description': '是否替换全部匹配，默认 false'},
    },
    required: ['path', 'old_text', 'new_text'],
  ),
  execute: (args) async {
    final bad = _guard(str(args['path']));
    if (bad != null) return bad;
    final abs = resolveWorkspacePath(str(args['path']));
    final oldText = args['old_text'] is String ? args['old_text'] as String : '';
    final newText = args['new_text'] is String ? args['new_text'] as String : '';
    if (oldText.isEmpty) return jsonEncode({'error': 'old_text 不能为空'});
    final f = File(abs);
    if (!await f.exists()) return jsonEncode({'error': '文件不存在', 'path': abs});
    final src = await f.readAsString();
    final count = oldText.allMatches(src).length;
    if (count == 0) {
      return jsonEncode({'error': 'old_text 在文件里没有匹配到', 'path': abs, 'bytes': src.length});
    }
    if (count > 1 && args['replace_all'] != true) {
      return jsonEncode({
        'error': 'old_text 匹配到 $count 处，不够唯一；请写更长的上下文，或设置 replace_all',
        'path': abs,
        'matches': count,
      });
    }
    final out = args['replace_all'] == true ? src.replaceAll(oldText, newText) : src.replaceFirst(oldText, newText);
    await f.writeAsString(out, flush: true);
    return jsonEncode({
      'ok': true,
      'path': abs,
      'replacements': args['replace_all'] == true ? count : 1,
      'bytes_before': src.length,
      'bytes_after': out.length,
    });
  },
);

AppTool buildWorkspaceListDirTool() => AppTool(
  name: workspaceListDirTool,
  displayName: '列目录',
  description: '列出一个目录下的条目（名称、类型、大小、修改时间）。',
  parameters: objectSchema({'path': strProp('目录路径；为空时列出应用支持目录'), 'limit': intProp('最多返回多少条，默认 100，上限 500')}),
  execute: (args) async {
    final raw = str(args['path']);
    final abs = raw.trim().isEmpty ? AppPaths.support.path : resolveWorkspacePath(raw);
    if (!isInsideWorkspace(abs)) {
      return jsonEncode({'error': '路径不在允许范围内', 'path': abs, 'allowed_roots': workspaceRoots()});
    }
    final d = Directory(abs);
    if (!await d.exists()) return jsonEncode({'error': '目录不存在', 'path': abs});
    final limit = (args['limit'] is int ? args['limit'] as int : 100).clamp(1, 500);
    final items = <Map<String, dynamic>>[];
    var more = false;
    await for (final e in d.list(followLinks: false)) {
      if (items.length >= limit) {
        more = true;
        break;
      }
      try {
        final st = await e.stat();
        items.add({
          'name': p.basename(e.path),
          'type': _entityTypeName(st.type),
          'bytes': st.type == FileSystemEntityType.directory ? null : st.size,
          'modified': st.modified.toIso8601String(),
        });
      } on Object catch (err) {
        items.add({'name': p.basename(e.path), 'error': '$err'});
      }
    }
    items.sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    return jsonEncode({'ok': true, 'path': abs, 'count': items.length, 'has_more': more, 'items': items});
  },
);

/// 构建全部工作区工具。
///
/// [allowWrite] 为 false 时只返回只读两件套（读文件 / 列目录）。
List<AppTool> buildWorkspaceTools({bool allowWrite = true}) {
  final out = <AppTool>[buildWorkspaceReadFileTool(), buildWorkspaceListDirTool()];
  if (allowWrite) {
    out.add(buildWorkspaceWriteFileTool());
    out.add(buildWorkspaceEditFileTool());
  }
  return out;
}

String str(dynamic v) => v is String ? v : (v == null ? '' : v.toString());

/// `FileSystemEntityType` 的可读名字。
///
/// 不用 `.name`：它在部分 Dart SDK 上不可用（CI 与本地版本可能不一致），
/// 显式映射最稳。
String _entityTypeName(FileSystemEntityType t) {
  if (t == FileSystemEntityType.file) return 'file';
  if (t == FileSystemEntityType.directory) return 'directory';
  if (t == FileSystemEntityType.link) return 'link';
  return 'other';
}
