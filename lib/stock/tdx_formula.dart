/// 通达信指标公式解释器 —— Dart 移植版。
///
/// 口径严格对齐 Kotlin 版 `chan/TdxFormula.kt`（后者已与 Python `tdx.py` 和 JS `tdx.js`
/// 在 210/211 个序列上逐值一致）。
///
/// 序列一律等长 `Float64List`，缺失为 NaN；语句先全局剥 `{注释}`，再按括号深度 0 的 `;` 切分。
///
/// 移植时保留的三个「坑」修复（这三个 bug 在原 JS 版里都真实存在过）：
///  1. 语句必须按 `;` 切分，不能按换行切（一行多句时只解析第一条）；
///     赋值分隔符要从左往右找，且跳过 `<=` `>=` `!=` 里的冒号。
///  2. `EVERY(C,N)` 的 N 必须按**标量**传给 COUNT，不能包成逐根数组（否则 count 越界恒 0）。
///  3. 解析完必须检查 token 是否耗尽，截断要报错而不是静默给出错误值。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 单条语句的解析/求值错误。
class FormulaError {
  FormulaError(this.line, this.text, this.message);

  final int line;
  final String text;
  final String message;

  @override
  String toString() => 'line $line [$text] $message';
}

/// 公式执行结果。[data] 为「已清洗」序列：NaN → 0，±Inf → ±1e18。
class FormulaResult {
  FormulaResult(this.data, this.errors, this.bars, {this.unknownFunctions = const []});

  final Map<String, Float64List> data;
  final List<FormulaError> errors;
  final int bars;

  /// 公式里出现过、但解释器没实现的函数名（去重、排序）。
  ///
  /// 这些函数一律返回全 NaN——不会中断整条公式（通达信函数太多，
  /// 全都直接报错会让常用公式也跑不了），但**必须让调用方知道**：
  /// 之前是静默忽略的，公式打错字或用了未支持函数时，
  /// 结果会是一串 NaN 而看不出任何异常。
  final List<String> unknownFunctions;

  bool get hasUnknownFunctions => unknownFunctions.isNotEmpty;
}

const double _infHuge = 1e18;

final RegExp _modifierRe = RegExp(
  r',\s*(NODRAW|COLOR[0-9A-Fa-f]{6}|COLOR[A-Z]+|LINETHICK\d+|POINTDOT|CROSSDOT|CIRCLEDOT|DOTLINE|NODRAW|VOLSTICK|STICK|LINESTICK)\b',
  caseSensitive: false,
);

const Set<String> _decorative = {
  'STICKLINE',
  'DRAWTEXT',
  'DRAWICON',
  'POLYLINE',
  'DRAWBAND',
  'DRAWTEXT_FIX',
  'DRAWKLINE',
};

const Map<String, String> _alias = {
  'CLOSE': 'C',
  'OPEN': 'O',
  'HIGH': 'H',
  'LOW': 'L',
  'VOL': 'V',
  'VOLUME': 'V',
  'AMOUNT': 'AMT',
};

const Set<String> _relOps = {'>', '<', '>=', '<=', '=', '==', '!=', '<>'};

// ------------------------------------------------------------------ 词法

enum _Kind { str, num, ident, op }

class _Tok {
  _Tok(this.kind, this.text);

  final _Kind kind;
  final String text;

  @override
  String toString() => '${kind.name}:$text';
}

const List<String> _ops2 = ['<=', '>=', '<>', '!=', ':=', '=='];
const String _ops1 = '-+*/(),;<>= ';

bool _isIdentStart(String c) => RegExp(r'[A-Za-z_\u00c0-\uffff]').hasMatch(c);
bool _isIdentPart(String c) => RegExp(r'[A-Za-z0-9_\u00c0-\uffff]').hasMatch(c);
bool _isDigit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

List<_Tok> _tokenize(String src) {
  final out = <_Tok>[];
  var i = 0;
  final len = src.length;
  while (i < len) {
    final c = src[i];
    if (c.trim().isEmpty) {
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      var j = i + 1;
      while (j < len && src[j] != c) {
        j++;
      }
      out.add(_Tok(_Kind.str, src.substring(i, math.min(j + 1, len))));
      i = j + 1;
      continue;
    }
    if (_isDigit(c) || (c == '.' && i + 1 < len && _isDigit(src[i + 1]))) {
      var j = i;
      while (j < len && _isDigit(src[j])) {
        j++;
      }
      if (j < len && src[j] == '.') {
        j++;
        while (j < len && _isDigit(src[j])) {
          j++;
        }
      }
      out.add(_Tok(_Kind.num, src.substring(i, j)));
      i = j;
      continue;
    }
    if (_isIdentStart(c)) {
      var j = i + 1;
      while (j < len && _isIdentPart(src[j])) {
        j++;
      }
      out.add(_Tok(_Kind.ident, src.substring(i, j)));
      i = j;
      continue;
    }
    final two = (i + 1 < len) ? src.substring(i, i + 2) : '';
    if (two.isNotEmpty && _ops2.contains(two)) {
      out.add(_Tok(_Kind.op, two));
      i += 2;
    } else if (_ops1.contains(c)) {
      out.add(_Tok(_Kind.op, c));
      i++;
    } else {
      // 与 JS 正则分词一致：匹配不到的字符（如 %）直接丢弃
      i++;
    }
  }
  return out;
}

// ------------------------------------------------------------------ 语法

enum _NK { num, variable, call, bin, unary }

class _Node {
  _Node(this.kind, {this.value = 0.0, this.text = '', this.args = const []});

  final _NK kind;
  final double value;
  final String text;
  final List<_Node> args;
}

class _ParseException implements Exception {
  _ParseException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _Parser {
  _Parser(this.toks);

  final List<_Tok> toks;
  int p = 0;

  _Tok? peek() => p < toks.length ? toks[p] : null;

  _Tok eat([String? expected]) {
    final tk = peek();
    if (expected != null && tk?.text != expected) {
      throw _ParseException('期望 $expected 实际 ${tk?.text ?? "<结束>"}');
    }
    p++;
    return tk ?? _Tok(_Kind.op, '');
  }

  bool isOp(String v) {
    final tk = peek();
    return tk != null && tk.kind == _Kind.op && tk.text == v;
  }

  bool isKw(String v) {
    final tk = peek();
    return tk != null && tk.kind == _Kind.ident && tk.text.toUpperCase() == v;
  }

  _Node parse() => _pOr();

  _Node _pOr() {
    var a = _pAnd();
    while (isKw('OR')) {
      eat();
      a = _Node(_NK.bin, text: 'OR', args: [a, _pAnd()]);
    }
    return a;
  }

  _Node _pAnd() {
    var a = _pCmp();
    while (isKw('AND')) {
      eat();
      a = _Node(_NK.bin, text: 'AND', args: [a, _pCmp()]);
    }
    return a;
  }

  _Node _pCmp() {
    var a = _pAdd();
    while (true) {
      final tk = peek();
      if (tk != null && tk.kind == _Kind.op && _relOps.contains(tk.text)) {
        eat();
        final op = switch (tk.text) {
          '==' => '=',
          '<>' => '!=',
          _ => tk.text,
        };
        a = _Node(_NK.bin, text: op, args: [a, _pAdd()]);
      } else {
        break;
      }
    }
    return a;
  }

  _Node _pAdd() {
    var a = _pMul();
    while (true) {
      final tk = peek();
      if (tk != null && tk.kind == _Kind.op && (tk.text == '+' || tk.text == '-')) {
        eat();
        a = _Node(_NK.bin, text: tk.text, args: [a, _pMul()]);
      } else {
        break;
      }
    }
    return a;
  }

  _Node _pMul() {
    var a = _pUnary();
    while (true) {
      final tk = peek();
      if (tk != null && tk.kind == _Kind.op && (tk.text == '*' || tk.text == '/')) {
        eat();
        a = _Node(_NK.bin, text: tk.text, args: [a, _pUnary()]);
      } else {
        break;
      }
    }
    return a;
  }

  _Node _pUnary() {
    final tk = peek();
    if (tk != null && tk.kind == _Kind.op && (tk.text == '-' || tk.text == '+')) {
      eat();
      return _Node(_NK.unary, text: tk.text, args: [_pUnary()]);
    }
    if (isKw('NOT')) {
      eat();
      return _Node(_NK.unary, text: 'NOT', args: [_pUnary()]);
    }
    return _pPrimary();
  }

  _Node _pPrimary() {
    final tk = peek();
    if (tk == null) {
      eat();
      return _Node(_NK.num, value: 0.0);
    }
    if (tk.kind == _Kind.num) {
      eat();
      return _Node(_NK.num, value: double.tryParse(tk.text) ?? 0.0);
    }
    if (tk.kind == _Kind.op && tk.text == '(') {
      eat('(');
      final e = parse();
      eat(')');
      return e;
    }
    if (tk.kind == _Kind.ident) {
      eat();
      final name = tk.text.toUpperCase();
      if (isOp('(')) {
        eat('(');
        final args = <_Node>[];
        if (!isOp(')')) {
          args.add(parse());
          while (isOp(',')) {
            eat(',');
            args.add(parse());
          }
        }
        eat(')');
        return _Node(_NK.call, text: name, args: args);
      }
      return _Node(_NK.variable, text: name);
    }
    if (tk.kind == _Kind.str) {
      eat();
      return _Node(_NK.num, value: 0.0);
    }
    // 兜底：吞掉避免死循环
    eat();
    return _Node(_NK.num, value: 0.0);
  }
}

// ------------------------------------------------------------ 序列函数

bool _isFiniteNum(double v) => v.isFinite;

Float64List _nanArr(int n) => Float64List(n)..fillRange(0, n, double.nan);

List<bool> _truth(Float64List x) => List<bool>.generate(x.length, (i) => x[i].isFinite && x[i] != 0.0);

/// NUMARG：取序列里最后一个有限值；没有则 0。
double _numArg(Float64List? a) {
  if (a == null) return 0.0;
  for (var i = a.length - 1; i >= 0; i--) {
    if (a[i].isFinite) return a[i];
  }
  return 0.0;
}

/// REF(X,N)：N 为逐根序列（null 视为常数 0）。
Float64List _ref(Float64List x, Float64List? n) {
  final len = x.length;
  final out = _nanArr(len);
  for (var i = 0; i < len; i++) {
    final kv = n == null ? 0.0 : n[i];
    if (!_isFiniteNum(kv)) continue;
    final k = kv.truncateToDouble();
    if (k <= 0) {
      out[i] = x[i];
    } else if (k <= i) {
      out[i] = x[i - k.toInt()];
    }
  }
  return out;
}

/// REF(X,k)：标量位移版本（内部用，语义同系数序列）。
Float64List _refScalar(Float64List x, int k) {
  final len = x.length;
  final out = _nanArr(len);
  final kk = math.max(0, k);
  for (var i = 0; i < len; i++) {
    if (kk <= 0) {
      out[i] = x[i];
    } else if (i >= kk) {
      out[i] = x[i - kk];
    }
  }
  return out;
}

/// REFX(X,N)：向未来取（未来函数）。i+k<L 才有值，否则 NaN。
Float64List _refx(Float64List x, Float64List? n) {
  final len = x.length;
  final out = _nanArr(len);
  for (var i = 0; i < len; i++) {
    final kv = n == null ? 0.0 : n[i];
    if (!_isFiniteNum(kv)) continue;
    final k = kv.truncateToDouble();
    if (k <= 0) {
      out[i] = x[i];
    } else if (i + k < len) {
      out[i] = x[i + k.toInt()];
    }
  }
  return out;
}

/// BARSLAST：距上次成立；无历史时返回 i（不是 i+1）。
Float64List _barsLast(List<bool> cond) {
  final len = cond.length;
  final out = Float64List(len);
  var last = -1;
  for (var i = 0; i < len; i++) {
    if (cond[i]) {
      last = i;
      out[i] = 0.0;
    } else {
      out[i] = last < 0 ? i.toDouble() : (i - last).toDouble();
    }
  }
  return out;
}

/// BARSNEXT：距下次成立；无未来时返回 0。
Float64List _barsNext(List<bool> cond) {
  final len = cond.length;
  final out = Float64List(len);
  var nxt = -1;
  for (var i = len - 1; i >= 0; i--) {
    if (cond[i]) {
      nxt = i;
      out[i] = 0.0;
    } else {
      out[i] = nxt < 0 ? 0.0 : (nxt - i).toDouble();
    }
  }
  return out;
}

/// COUNT(COND,N)：前缀和 cs[i+1]-cs[max(0,i-k+1)]。
Float64List _countImpl(List<bool> cond, double Function(int) kAt) {
  final len = cond.length;
  final cs = Float64List(len + 1);
  for (var i = 0; i < len; i++) {
    cs[i + 1] = cs[i] + (cond[i] ? 1.0 : 0.0);
  }
  final out = Float64List(len);
  for (var i = 0; i < len; i++) {
    var k = kAt(i);
    if (!_isFiniteNum(k)) k = 0.0;
    k = k.truncateToDouble();
    final idx = i - k + 1.0;
    if (idx <= 0.0) {
      out[i] = cs[i + 1] - cs[0];
    } else if (idx > len) {
      out[i] = double.nan;
    } else {
      out[i] = cs[i + 1] - cs[idx.toInt()];
    }
  }
  return out;
}

/// SUMBARS(COND,N)：向前累加到第 N 个成立所经历的周期数（含当前）。
Float64List _sumBars(List<bool> cond, double nRaw) {
  final len = cond.length;
  final out = Float64List(len);
  final n = math.max(1.0, nRaw.truncateToDouble());
  for (var i = 0; i < len; i++) {
    var c = 0;
    var j = i;
    while (j >= 0) {
      if (cond[j]) {
        c++;
        if (c >= n) break;
      }
      j--;
    }
    out[i] = c >= n ? (i - j + 1).toDouble() : i.toDouble();
  }
  return out;
}

/// FILTERX(C,N)：C 成立时把 [i-k,i-1] 清零并置 out[i]=1。
Float64List _filterX(List<bool> cond, Float64List? n) {
  final len = cond.length;
  final out = Float64List(len);
  for (var i = 0; i < len; i++) {
    if (!cond[i]) continue;
    final kv = n == null ? 0.0 : n[i];
    final k = _isFiniteNum(kv) ? kv.truncateToDouble() : 0.0;
    final s = k >= i ? 0 : (i - k).toInt();
    for (var j = s; j < i; j++) {
      out[j] = 0.0;
    }
    out[i] = 1.0;
  }
  return out;
}

/// BACKSET(C,N)：C 成立且 k 时，把 [max(0,i-k),i] 置 1。
Float64List _backset(List<bool> cond, Float64List? n) {
  final len = cond.length;
  final out = Float64List(len);
  for (var i = 0; i < len; i++) {
    if (!cond[i]) continue;
    final kv = n == null ? 0.0 : n[i];
    final k = _isFiniteNum(kv) ? kv.truncateToDouble() : 0.0;
    final s = k >= i ? 0 : (i - k).toInt();
    for (var j = s; j <= i; j++) {
      out[j] = 1.0;
    }
  }
  return out;
}

/// CROSS(A,B)：a>b && ref(a,1)<=ref(b,1)。
Float64List _cross(Float64List a, Float64List b) {
  final len = a.length;
  final ra = _refScalar(a, 1);
  final rb = _refScalar(b, 1);
  return Float64List.fromList(
    List<double>.generate(len, (i) {
      return (a[i] > b[i] && ra[i] <= rb[i]) ? 1.0 : 0.0;
    }),
  );
}

/// VALUEWHEN(C,X)：C 成立则刷新 cur，输出 cur。
Float64List _valueWhen(List<bool> cond, Float64List x) {
  final len = x.length;
  final out = _nanArr(len);
  var cur = double.nan;
  for (var i = 0; i < len; i++) {
    if (cond[i]) cur = x[i];
    out[i] = cur;
  }
  return out;
}

/// EMA(X,N)：a=2/(n+1)，首根取 X[0]，遇 NaN 沿用 prev。
Float64List _ema(Float64List x, double nRaw) {
  final len = x.length;
  final out = _nanArr(len);
  final a = 2.0 / (nRaw + 1.0);
  var prev = double.nan;
  for (var i = 0; i < len; i++) {
    final v = x[i];
    if (!_isFiniteNum(v)) {
      out[i] = prev;
      continue;
    }
    prev = !_isFiniteNum(prev) ? v : a * v + (1 - a) * prev;
    out[i] = prev;
  }
  return out;
}

/// SMA(X,N,M)：prev=(M*v+(N-M)*prev)/N，首根取 v。
Float64List _sma(Float64List x, double nRaw, double mRaw) {
  final len = x.length;
  final out = _nanArr(len);
  var prev = double.nan;
  for (var i = 0; i < len; i++) {
    final v = x[i];
    if (!_isFiniteNum(v)) {
      out[i] = prev;
      continue;
    }
    prev = !_isFiniteNum(prev) ? v : (mRaw * v + (nRaw - mRaw) * prev) / nRaw;
    out[i] = prev;
  }
  return out;
}

/// MA(X,N)：窗口内有限值求平均（不足 N 也用已有根数）。
Float64List _ma(Float64List x, double nRaw) {
  final n = math.max(1.0, nRaw.truncateToDouble());
  final len = x.length;
  final out = _nanArr(len);
  for (var i = 0; i < len; i++) {
    final s = n >= i + 1 ? 0 : (i - n + 1).toInt();
    var sum = 0.0;
    var c = 0;
    for (var j = s; j <= i; j++) {
      final v = x[j];
      if (_isFiniteNum(v)) {
        sum += v;
        c++;
      }
    }
    out[i] = c != 0 ? sum / c : double.nan;
  }
  return out;
}

/// HHV/LLV(X,N)：窗口忽略 NaN；全 NaN → NaN。
Float64List _extreme(Float64List x, Float64List? n, bool wantMax) {
  final len = x.length;
  final out = _nanArr(len);
  for (var i = 0; i < len; i++) {
    var k = n == null ? len.toDouble() : n[i];
    if (!_isFiniteNum(k)) k = 1.0;
    k = math.max(1.0, k.truncateToDouble());
    final s = k >= i + 1 ? 0 : (i - k + 1).toInt();
    var best = wantMax ? double.negativeInfinity : double.infinity;
    var found = false;
    for (var j = s; j <= i; j++) {
      final v = x[j];
      if (_isFiniteNum(v)) {
        if (wantMax) {
          if (v > best) best = v;
        } else {
          if (v < best) best = v;
        }
        found = true;
      }
    }
    out[i] = found ? best : double.nan;
  }
  return out;
}

/// SUM(X,N)：前缀和窗口求和，忽略 NaN。
Float64List _sumImpl(Float64List x, double Function(int) kAt) {
  final len = x.length;
  final cs = Float64List(len + 1);
  for (var i = 0; i < len; i++) {
    cs[i + 1] = cs[i] + (_isFiniteNum(x[i]) ? x[i] : 0.0);
  }
  final out = Float64List(len);
  for (var i = 0; i < len; i++) {
    var k = kAt(i);
    if (!_isFiniteNum(k)) k = (i + 1).toDouble();
    k = math.max(1.0, k.truncateToDouble());
    final s = k >= i + 1 ? 0 : (i - k + 1).toInt();
    out[i] = cs[i + 1] - cs[s];
  }
  return out;
}

// -------------------------------------------------------------- 执行器

class _Ctx {
  _Ctx(this.n, this.data, this.unknown, {this.symbol, this.name});

  final int n;
  final Map<String, Float64List> data;

  /// 当前标的，供 CODELIKE 判断板块前缀。
  final String? symbol;

  /// 当前标的名称，供 NAMELIKE 判断（ST、退市整理等）。
  final String? name;

  /// 收集未实现的函数名。挂在 ctx 上而不是用全局变量：
  /// 并发调用（面板 + AI 工具同时算）时全局 Set 会串数据。
  final Set<String> unknown;

  Float64List? get(String name) {
    final direct = data[name];
    if (direct != null) return direct;
    var base = name;
    if (base.endsWith('_')) base = base.substring(0, base.length - 1);
    final b = data[base];
    if (b != null) return b;
    final alias = _alias[base];
    if (alias != null) {
      final al = data[alias];
      if (al != null) return al;
    }
    return null;
  }
}

Float64List _evalNode(_Node nd, _Ctx ctx) {
  final n = ctx.n;
  switch (nd.kind) {
    case _NK.num:
      final v = nd.value;
      return Float64List(n)..fillRange(0, n, v);
    case _NK.variable:
      final v = ctx.get(nd.text);
      if (v == null) return _nanArr(n);
      if (v.length == n) return v;
      return Float64List.fromList(List<double>.generate(n, (i) => i < v.length ? v[i] : double.nan));
    case _NK.unary:
      final x = _evalNode(nd.args[0], ctx);
      switch (nd.text) {
        case '-':
          return Float64List.fromList(List<double>.generate(n, (i) => -x[i]));
        case '+':
          return x;
        default:
          final t = _truth(x);
          return Float64List.fromList(List<double>.generate(n, (i) => t[i] ? 0.0 : 1.0));
      }
    case _NK.bin:
      return _evalBin(nd, ctx);
    case _NK.call:
      return _callFn(nd.text, nd.args, ctx);
  }
}

Float64List _evalBin(_Node nd, _Ctx ctx) {
  final n = ctx.n;
  final a = _evalNode(nd.args[0], ctx);
  final b = _evalNode(nd.args[1], ctx);
  final op = nd.text;
  final out = Float64List(n);
  switch (op) {
    case '+':
      for (var i = 0; i < n; i++) {
        out[i] = a[i] + b[i];
      }
    case '-':
      for (var i = 0; i < n; i++) {
        out[i] = a[i] - b[i];
      }
    case '*':
      for (var i = 0; i < n; i++) {
        out[i] = a[i] * b[i];
      }
    case '/':
      for (var i = 0; i < n; i++) {
        out[i] = b[i] == 0.0 ? double.nan : a[i] / b[i];
      }
    case '>':
      for (var i = 0; i < n; i++) {
        out[i] = a[i] > b[i] ? 1.0 : 0.0;
      }
    case '<':
      for (var i = 0; i < n; i++) {
        out[i] = a[i] < b[i] ? 1.0 : 0.0;
      }
    case '>=':
      for (var i = 0; i < n; i++) {
        out[i] = a[i] >= b[i] ? 1.0 : 0.0;
      }
    case '<=':
      for (var i = 0; i < n; i++) {
        out[i] = a[i] <= b[i] ? 1.0 : 0.0;
      }
    case '=':
      {
        // 一侧全是 NaN（DRAWNULL）时退化为 isnan 判断
        var aAllNaN = true;
        var bAllNaN = true;
        for (var i = 0; i < n; i++) {
          if (!a[i].isNaN) aAllNaN = false;
          if (!b[i].isNaN) bAllNaN = false;
        }
        if (bAllNaN) {
          for (var i = 0; i < n; i++) {
            out[i] = a[i].isNaN ? 1.0 : 0.0;
          }
        } else if (aAllNaN) {
          for (var i = 0; i < n; i++) {
            out[i] = b[i].isNaN ? 1.0 : 0.0;
          }
        } else {
          for (var i = 0; i < n; i++) {
            final av = a[i];
            final bv = b[i];
            out[i] = (av.isNaN || bv.isNaN) ? 0.0 : (av == bv ? 1.0 : 0.0);
          }
        }
      }
    case '!=':
      {
        var aAllNaN = true;
        var bAllNaN = true;
        for (var i = 0; i < n; i++) {
          if (!a[i].isNaN) aAllNaN = false;
          if (!b[i].isNaN) bAllNaN = false;
        }
        if (bAllNaN) {
          for (var i = 0; i < n; i++) {
            out[i] = a[i].isNaN ? 0.0 : 1.0;
          }
        } else if (aAllNaN) {
          for (var i = 0; i < n; i++) {
            out[i] = b[i].isNaN ? 0.0 : 1.0;
          }
        } else {
          for (var i = 0; i < n; i++) {
            final av = a[i];
            final bv = b[i];
            out[i] = (av.isNaN || bv.isNaN) ? 1.0 : (av != bv ? 1.0 : 0.0);
          }
        }
      }
    case 'AND':
      {
        final ta = _truth(a);
        final tb = _truth(b);
        for (var i = 0; i < n; i++) {
          out[i] = (ta[i] && tb[i]) ? 1.0 : 0.0;
        }
      }
    case 'OR':
      {
        final ta = _truth(a);
        final tb = _truth(b);
        for (var i = 0; i < n; i++) {
          out[i] = (ta[i] || tb[i]) ? 1.0 : 0.0;
        }
      }
    default:
      throw _ParseException('未知运算符 $op');
  }
  return out;
}

Float64List _callFn(String name, List<_Node> args, _Ctx ctx) {
  final n = ctx.n;
  final a = args.map((e) => _evalNode(e, ctx)).toList();
  final a0 = a.isNotEmpty ? a[0] : _nanArr(n);
  final a1 = a.length > 1 ? a[1] : null;
  final a2 = a.length > 2 ? a[2] : null;

  switch (name) {
    case 'IF':
      if (a.length < 3) return _nanArr(n);
      final c = _truth(a[0]);
      return Float64List.fromList(List<double>.generate(n, (i) => c[i] ? a[1][i] : a[2][i]));
    case 'REF':
      return _ref(a0, a1);
    case 'REFX':
      return _refx(a0, a1);
    case 'BARSLAST':
      return _barsLast(_truth(a0));
    case 'BARSNEXT':
      return _barsNext(_truth(a0));
    case 'COUNT':
      return _countImpl(_truth(a0), (i) => a1 == null ? n.toDouble() : a1[i]);
    case 'SUMBARS':
      return _sumBars(_truth(a0), _numArg(a1));
    case 'FILTERX':
      return _filterX(_truth(a0), a1);
    case 'BACKSET':
      return _backset(_truth(a0), a1);
    case 'CROSS':
      if (a.length < 2) return _nanArr(n);
      return _cross(a0, a1!);
    case 'VALUEWHEN':
      if (a.length < 2) return _nanArr(n);
      return _valueWhen(_truth(a0), a1!);
    case 'HHV':
      return _extreme(a0, a1, true);
    case 'LLV':
      return _extreme(a0, a1, false);
    case 'MA':
      if (a.length < 2) return _nanArr(n);
      return _ma(a0, _numArg(a1));
    case 'EMA':
      if (a.length < 2) return _nanArr(n);
      return _ema(a0, _numArg(a1));
    case 'SMA':
      if (a.length < 3) return _nanArr(n);
      return _sma(a0, _numArg(a1), _numArg(a2));
    case 'SUM':
      return _sumImpl(a0, (i) => a1 == null ? n.toDouble() : a1[i]);
    case 'EVERY':
      {
        // ★ N 必须按标量传：包成逐根数组时 count 会取到越界 0，EVERY 恒为 0。
        final k = _numArg(a1).truncateToDouble();
        final cnt = _countImpl(_truth(a0), (_) => k);
        return Float64List.fromList(List<double>.generate(n, (i) => cnt[i] >= k ? 1.0 : 0.0));
      }
    case 'NOT':
      {
        final t = _truth(a0);
        return Float64List.fromList(List<double>.generate(n, (i) => t[i] ? 0.0 : 1.0));
      }
    case 'ABS':
      return Float64List.fromList(List<double>.generate(n, (i) => a0[i].abs()));
    case 'MAX':
      if (a.length < 2) return _nanArr(n);
      return Float64List.fromList(
        List<double>.generate(n, (i) {
          final x = a0[i];
          final y = a[1][i];
          if (x.isNaN || y.isNaN) return double.nan;
          return x >= y ? x : y;
        }),
      );
    case 'MIN':
      if (a.length < 2) return _nanArr(n);
      return Float64List.fromList(
        List<double>.generate(n, (i) {
          final x = a0[i];
          final y = a[1][i];
          if (x.isNaN || y.isNaN) return double.nan;
          return x <= y ? x : y;
        }),
      );
    case 'SQRT':
      return Float64List.fromList(List<double>.generate(n, (i) => math.sqrt(a0[i].abs())));
    case 'CONST':
      {
        final v = _numArg(a0);
        return Float64List(n)..fillRange(0, n, v);
      }
    case 'DRAWLINE':
      return _drawLine(a, n);
    case 'DRAWNULL':
      return _nanArr(n);
    // ---- 这 4 个以前是未实现、直接返回 NaN ----
    //
    // 它们只用于涨停/跌停价与板块判定（公式里都是 NODRAW），不影响笔和中枢，
    // 但缺了会让模型看到 formulaErrors，从而对整份结构打折扣。
    case 'CODELIKE':
      {
        // CODELIKE('33')：代码是否以该前缀开头（板块/市场判定）
        final prefix = args.isNotEmpty ? args[0].text.trim().toLowerCase() : '';
        final sym = (ctx.symbol ?? '').toLowerCase().replaceFirst(RegExp(r'^(sh|sz|bj)'), '');
        final ok = prefix.isNotEmpty && sym.startsWith(prefix);
        return Float64List(n)..fillRange(0, n, ok ? 1.0 : 0.0);
      }
    case 'NAMELIKE':
      {
        // NAMELIKE('ST')：名称是否包含该片段
        final key = args.isNotEmpty ? args[0].text.trim().toUpperCase() : '';
        final nm = (ctx.name ?? '').toUpperCase();
        final ok = key.isNotEmpty && nm.contains(key);
        return Float64List(n)..fillRange(0, n, ok ? 1.0 : 0.0);
      }
    case 'ZTPRICE':
    case 'DTPRICE':
      {
        // ZTPRICE(REF(CLOSE,1), 0.1)：基准价 × (1 ± 比例)，四舍五入到分
        final base = a0;
        final ratio = (a1 != null && a1.isNotEmpty && !a1[0].isNaN) ? a1[0] : 0.1;
        final up = name == 'ZTPRICE';
        final out = Float64List(n);
        for (var i = 0; i < n; i++) {
          final v = base[i];
          out[i] = v.isNaN ? double.nan : ((v * (1 + (up ? ratio : -ratio))) * 100).roundToDouble() / 100;
        }
        return out;
      }
    default:
      if (_decorative.contains(name)) return _nanArr(n);
      // 未实现函数（NAMELIKE/CODELIKE/ZTPRICE/DATE/...）：返回 NaN 但不中断公式，
      // 同时记录名字，交给调用方提示用户。
      ctx.unknown.add(name);
      return _nanArr(n);
  }
}

/// DRAWLINE(C1,P1,C2,P2)：每段从 C1 成立处线性连到其后首个 C2 成立处，后段覆盖前段。
Float64List _drawLine(List<Float64List> a, int n) {
  final out = _nanArr(n);
  if (a.length < 4) return out;
  final c1 = _truth(a[0]);
  final p1 = a[1];
  final c2 = _truth(a[2]);
  final p2 = a[3];
  var di = 0;
  while (di < n) {
    while (di < n && !c1[di]) {
      di++;
    }
    if (di >= n) break;
    final i1 = di;
    var i2 = -1;
    var dj = i1 + 1;
    while (dj < n) {
      if (c2[dj]) {
        i2 = dj;
        break;
      }
      dj++;
    }
    if (i2 < 0) {
      // 找不到终点：跳过这个起点，继续找下一段（与 JS 的 break 等价）
      di = i1 + 1;
      continue;
    }
    final v1 = p1[i1];
    final v2 = p2[i2];
    if (_isFiniteNum(v1) && _isFiniteNum(v2)) {
      for (var dk = i1; dk <= i2; dk++) {
        final ratio = i2 == i1 ? 0.0 : (dk - i1).toDouble() / (i2 - i1).toDouble();
        out[dk] = v1 + (v2 - v1) * ratio;
      }
    }
    di = i2 + 1;
  }
  return out;
}

// ---------------------------------------------------------- 公式执行

/// 按 ';' 切语句，尊重括号深度（通达信用 ';' 分隔，不是换行）。
List<String> _splitStatements(String src) {
  final out = <String>[];
  final buf = StringBuffer();
  var depth = 0;
  for (var i = 0; i < src.length; i++) {
    final ch = src[i];
    if (ch == '(') depth++;
    if (ch == ')') depth = math.max(0, depth - 1);
    if (ch == ';' && depth == 0) {
      out.add(buf.toString());
      buf.clear();
      continue;
    }
    buf.write(ch);
  }
  out.add(buf.toString());
  return out;
}

/// 找不在括号/引号内的赋值分隔符位置。
int _findSep(String line, String sep) {
  var depth = 0;
  var inStr = false;
  var i = 0;
  while (i < line.length) {
    final ch = line[i];
    if (inStr) {
      if (ch == "'" || ch == '"') inStr = false;
      i++;
      continue;
    }
    if (ch == "'" || ch == '"') {
      inStr = true;
      i++;
      continue;
    }
    if (ch == '(') {
      depth++;
    } else if (ch == ')') {
      depth--;
    } else if (depth == 0 && line.startsWith(sep, i)) {
      final prev = i > 0 ? line[i - 1] : '\u0000';
      if (sep == ':' && (prev == '<' || prev == '>' || prev == '!')) {
        i++;
        continue;
      }
      return i;
    }
    i++;
  }
  return -1;
}

final RegExp _commentRe = RegExp(r'\{[\s\S]*?}');

/// 执行整段公式。
///
/// [ohlcv] 行情序列，键可用 `o/h/l/c/v` 或 `OPEN/HIGH/LOW/CLOSE/VOL`。
FormulaResult runFormula(String text, Map<String, Float64List> ohlcv, {String? symbol, String? name}) {
  final close = ohlcv['c'] ?? ohlcv['CLOSE'] ?? ohlcv['C'];
  if (close == null) {
    return FormulaResult({}, [FormulaError(0, '', '缺少收盘价序列')], 0, unknownFunctions: const []);
  }
  final n = close.length;
  final data = <String, Float64List>{};
  for (final e in ohlcv.entries) {
    data[e.key.toUpperCase()] = e.value;
  }
  final unknown = <String>{};
  final ctx = _Ctx(n, data, unknown, symbol: symbol, name: name);
  final errors = <FormulaError>[];

  // ★ 先全局剥掉 {注释}（可跨行），再按 ';' 切句
  final src = text.replaceAll(_commentRe, '');
  final statements = _splitStatements(src);
  for (var li = 0; li < statements.length; li++) {
    final line = statements[li].trim();
    if (line.isEmpty) continue;

    final isAssign = line.contains(':=');
    final sep = isAssign ? ':=' : ':';
    final idx = _findSep(line, sep);
    if (idx < 0) continue;

    final name = line.substring(0, idx).trim();
    var exprPart = line.substring(idx + sep.length);

    // 去掉 NODRAW / COLORxxxxxx / LINETHICKx 等绘图修饰
    exprPart = exprPart.replaceAll(_modifierRe, '');

    try {
      final toks = _tokenize(exprPart);
      final parser = _Parser(toks);
      final ast = parser.parse();
      final stray = <String>[];
      for (var rt = parser.p; rt < toks.length; rt++) {
        final v = toks[rt].text;
        if (v != ',' && v != ')') stray.add(v);
      }
      if (stray.isNotEmpty) {
        errors.add(
          FormulaError(
            li + 1,
            line.length > 80 ? line.substring(0, 80) : line,
            '语句未完整消费，剩余 token: ${stray.take(8).join(' ')}',
          ),
        );
      }
      data[name.toUpperCase()] = _evalNode(ast, ctx);
    } catch (e) {
      errors.add(FormulaError(li + 1, line.length > 80 ? line.substring(0, 80) : line, e.toString()));
    }
  }

  // 与引擎侧 np.nan_to_num 口径对齐：NaN -> 0，±Inf -> ±1e18
  final clean = <String, Float64List>{};
  for (final entry in data.entries) {
    final s = entry.value;
    final dst = Float64List(s.length);
    for (var ci = 0; ci < s.length; ci++) {
      final v = s[ci];
      if (v.isFinite) {
        dst[ci] = v;
      } else if (v == double.infinity) {
        dst[ci] = _infHuge;
      } else if (v == double.negativeInfinity) {
        dst[ci] = -_infHuge;
      } else {
        dst[ci] = 0.0;
      }
    }
    clean[entry.key] = dst;
  }
  final unknownSorted = unknown.toList()..sort();
  return FormulaResult(clean, errors, n, unknownFunctions: unknownSorted);
}
