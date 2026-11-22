import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../agents/tool_run_context.dart';
import '../core/net.dart';
import '../core/paths.dart';
import '../core/util.dart';
import 'tool.dart';

/// 子智能体（以及主智能体）的通用出网工具。
///
/// 为什么单独做一个：清水的子智能体之所以能"干活"，是因为网络能力是
/// **无条件注入**的基础能力，不受工具白名单影响。我们这边原来的子智能体
/// 只能拿到股票工具，遇到网页 / API / 下载就只能说"拿不到"。
///
/// 设计边界：
/// - 只允许 http/https；
/// - 响应体超过 [maxBytes] 直接截断，不把上下文撑爆；
/// - 二进制（图片/压缩包/APK）不返回正文，只返回大小与落盘路径；
/// - 允许 save_to 落盘，路径必须落在工作区或允许的根目录内。
const httpToolName = 'http_request';

/// 单次响应最多读多少字节。
const _maxBytes = 512 * 1024;

/// 允许写入的根目录；不在其中的路径会被拒绝。
List<String> _allowedRoots() {
  final roots = <String>[AppPaths.support.path];
  final home = Platform.environment['HOME'];
  if (home != null && home.isNotEmpty) roots.add(home);
  // Android 与 iOS 的沙箱容器
  if (Platform.isAndroid) {
    roots.add('/storage/emulated/0');
    roots.add('/data/local/tmp');
  }
  roots.add(Directory.systemTemp.path);
  return roots;
}

bool _insideAllowedRoot(String abs) {
  for (final root in _allowedRoots()) {
    if (abs == root || abs.startsWith('$root${Platform.pathSeparator}')) return true;
    if (abs.startsWith('$root/')) return true;
  }
  return false;
}

/// 文本内容才返回正文；其余按二进制处理，避免把二进制塞进上下文。
bool _looksTextual(String? mime, List<int> head) {
  final m = (mime ?? '').toLowerCase();
  if (m.startsWith('text/')) return true;
  if (m.contains('json') || m.contains('xml') || m.contains('javascript') || m.contains('x-www-form-urlencoded')) {
    return true;
  }
  if (m.startsWith('image/') ||
      m.startsWith('video/') ||
      m.startsWith('audio/') ||
      m.contains('zip') ||
      m.contains('octet-stream')) {
    return false;
  }
  // 没有 mime：看头部有没有 NUL 字节，有就当二进制
  for (final b in head) {
    if (b == 0) return false;
  }
  return true;
}

/// 发请求但**不**把非 2xx 当异常：抓 404 页面、看错误体也是正常需求。
Future<http.StreamedResponse> _send(
  String method,
  Uri url, {
  Map<String, String> headers = const {},
  String? body,
  CancelToken? cancel,
}) {
  final req = http.AbortableRequest(method, url, abortTrigger: cancel?.future);
  if (headers.isNotEmpty) req.headers.addAll(headers);
  if (!req.headers.containsKey('User-Agent')) {
    req.headers['User-Agent'] =
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';
  }
  if (body != null) req.bodyBytes = utf8.encode(body);
  return Net.sendRequest(req);
}

AppTool buildHttpTool() {
  return AppTool(
    name: httpToolName,
    displayName: '网络请求',
    description:
        '发任意 HTTP(S) 请求，读取网页 / 调用 API / 下载文件。'
        'GET 直接取正文；POST/PUT/PATCH 用 body；需要落盘时给 save_to。'
        '网页正文最多返回 ${_maxBytes ~/ 1024} KB，超出会截断；图片、压缩包、APK 等二进制不返回正文，只返回大小与落盘路径。',
    parameters: objectSchema(
      {
        'url': strProp('完整地址，必须以 http:// 或 https:// 开头'),
        'method': strProp('请求方法', enumValues: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD']),
        'headers': {
          'type': 'object',
          'description': '附加请求头，例如 {"Referer": "https://finance.sina.com.cn"}',
          'additionalProperties': {'type': 'string'},
        },
        'body': strProp('请求体；字符串原样发送，对象会被 JSON 序列化'),
        'save_to': strProp('把响应原始字节保存到这个路径（写文件时用）'),
        'max_chars': intProp('正文最多返回多少字符，默认 8000'),
      },
      required: ['url'],
    ),
    promptHint:
        '需要联网时直接调用 `$httpToolName`：取网页、调行情/公开 API、下载文件都走它。'
        '拿不到就明确说拿不到，不要凭印象编造数据。',
    execute: (args) async {
      final raw = asStr(args['url']).trim();
      final uri = Uri.tryParse(raw);
      if (uri == null || !uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return jsonEncode({'error': 'url 无效，必须是 http:// 或 https:// 开头', 'url': raw});
      }
      final method = (asStr(args['method']).trim().isEmpty ? 'GET' : asStr(args['method']).trim()).toUpperCase();
      final headers = <String, String>{};
      final h = asMapOrNull(args['headers']);
      if (h != null) {
        for (final e in h.entries) {
          headers[e.key] = asStr(e.value);
        }
      }
      final bodyRaw = args['body'];
      final String? body;
      if (bodyRaw == null) {
        body = null;
      } else if (bodyRaw is String) {
        body = bodyRaw;
      } else {
        body = jsonEncode(bodyRaw);
      }
      final maxChars = (args['max_chars'] is int ? args['max_chars'] as int : 8000).clamp(200, 60000).toInt();
      final saveTo = asStr(args['save_to']).trim();
      final cancel = currentToolRun()?.cancel;
      final sw = Stopwatch()..start();

      try {
        if (saveTo.isNotEmpty) {
          final abs = p.normalize(p.isAbsolute(saveTo) ? saveTo : p.join(AppPaths.support.path, saveTo));
          if (!_insideAllowedRoot(abs)) {
            return jsonEncode({'error': 'save_to 路径不在允许范围内', 'path': abs, 'allowed_roots': _allowedRoots()});
          }
          final res = await _send(
            method,
            uri,
            headers: headers,
            body: body,
            cancel: cancel,
          ).timeout(const Duration(seconds: 120));
          final file = File(abs);
          await file.parent.create(recursive: true);
          final sink = file.openWrite();
          var total = 0;
          await for (final List<int> chunk in res.stream) {
            total += chunk.length;
            sink.add(chunk);
          }
          await sink.flush();
          await sink.close();
          sw.stop();
          return jsonEncode({
            'ok': res.statusCode >= 200 && res.statusCode < 400,
            'status': res.statusCode,
            'url': uri.toString(),
            'method': method,
            'saved_to': abs,
            'bytes': total,
            'mime': res.headers['content-type'],
            'ms': sw.elapsedMilliseconds,
          });
        }

        final res = await _send(
          method,
          uri,
          headers: headers,
          body: body,
          cancel: cancel,
        ).timeout(const Duration(seconds: 90));
        final out = <int>[];
        var truncated = false;
        await for (final List<int> chunk in res.stream) {
          if (out.length >= _maxBytes) {
            truncated = true;
            break;
          }
          final room = _maxBytes - out.length;
          out.addAll(chunk.length <= room ? chunk : chunk.sublist(0, room));
          if (out.length >= _maxBytes) {
            truncated = true;
            break;
          }
        }
        sw.stop();
        final mime = res.headers['content-type'];
        final textual = _looksTextual(mime, out.length > 64 ? out.sublist(0, 64) : out);
        if (!textual) {
          return jsonEncode({
            'ok': false,
            'status': res.statusCode,
            'url': uri.toString(),
            'method': method,
            'mime': mime,
            'bytes': out.length,
            'truncated': truncated,
            'error': '响应是二进制内容，没有返回正文；如果需要文件，请给 save_to 参数',
            'ms': sw.elapsedMilliseconds,
          });
        }
        var text = utf8.decode(out, allowMalformed: true);
        final clipped = text.length > maxChars;
        if (clipped) text = text.substring(0, maxChars);
        return jsonEncode({
          'ok': res.statusCode >= 200 && res.statusCode < 400,
          'status': res.statusCode,
          'url': uri.toString(),
          'method': method,
          'mime': mime,
          'chars': text.length,
          'truncated': truncated || clipped,
          'body': text,
          'ms': sw.elapsedMilliseconds,
        });
      } on Object catch (e) {
        sw.stop();
        return jsonEncode({
          'ok': false,
          'url': uri.toString(),
          'method': method,
          'error': '$e',
          'ms': sw.elapsedMilliseconds,
        });
      }
    },
  );
}
