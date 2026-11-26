/// 发给模型前裁剪工具结果。
///
/// 为什么要有：`stock_levels` 一次 8 只 × 5 周期能返回几万字符，`http_request`
/// 抓网页更是没有上限。这些原样塞进上下文，会把前面说过的内容挤掉，
/// 表现就是模型「忘了刚才的约束」「只回答最后一条」。
///
/// 存储和界面都保留完整内容，只有发往 provider 的那一份被裁剪——
/// 用户点开工具卡片仍然能看到全文。
///
/// 裁剪点在尾部而不是中间：工具结果通常是「摘要在前、明细在后」，
/// 保留开头能让模型先拿到结论和关键字段。
///
/// 这个文件刻意不 import 任何东西，好让纯 Dart 脚本能直接跑自检。
library;

/// 超过这个长度就会裁剪。
const kToolOutputLimit = 12000;

/// 裁剪后保留的长度。留一点余量，让「刚好超一点」的结果不至于被砍太多。
const kToolOutputKeep = 9000;

/// 把工具返回给模型的那一份裁到 [kToolOutputLimit] 以内。
///
/// 没有超长就原样返回，不做任何归一化——工具结果是模型要读的原文。
String toolOutputForModel(String? output) {
  final s = output ?? '';
  if (s.length <= kToolOutputLimit) return s;
  final head = s.substring(0, kToolOutputKeep);
  final dropped = s.length - kToolOutputKeep;
  return '$head\n\n'
      '[结果过长已截断：原始 ${s.length} 字符，这里只保留前 $kToolOutputKeep 字符，省略 $dropped 字符。'
      '需要完整数据请缩小查询范围——减少股票数量、减少周期、减少 K 线根数，或者只问一个字段。]';
}
