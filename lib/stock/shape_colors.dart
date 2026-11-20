/// 图元语义颜色的实际色值。
///
/// 单独一个文件是为了让 [chart_shapes.dart] 的模型层不依赖 Flutter，
/// 这样它在纯 Dart 环境里也能跑序列化测试。
library;

import 'package:flutter/material.dart';

import 'chart_shapes.dart';

/// 语义颜色 → 具体色值。用固定的实盘配色，不跟随主题强调色（否则涨跌色会错乱）。
Color shapeColorValue(ShapeColor c) => switch (c) {
  ShapeColor.up => const Color(0xFFE5484D),
  ShapeColor.down => const Color(0xFF30A46C),
  ShapeColor.resist => const Color(0xFFE8A33D),
  ShapeColor.support => const Color(0xFF4A8FE7),
  ShapeColor.stop => const Color(0xFFB065D4),
  ShapeColor.target => const Color(0xFF2AB7A9),
  ShapeColor.accent => const Color(0xFF8A8F98),
};
