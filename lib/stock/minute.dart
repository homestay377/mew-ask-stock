/// 分时数据：当天逐分钟的价格与成交量。
///
/// 接口：`web.ifzq.gtimg.cn/appstock/app/minute/query?code=sz300274`，
/// **必须带 `Referer: https://gu.qq.com/`**，否则拿不到数据。
///
/// 返回格式（实测）：`"0930 70.71 2647 18716937.00"` =
/// 时间(时分) 现价 成交量(手) 成交额(元)，每天 9:30–11:30、13:00–15:00 共 241 点。
library;

/// 分时图的一个点。
class MinutePoint {
  MinutePoint(this.time, this.price, this.volume, this.amount);

  /// `HHmm`，如 `0930`
  final String time;
  final double price;

  /// 累计成交量（手）
  final double volume;

  /// 累计成交额（元）
  final double amount;

  /// `0930` → `09:30`
  String get label => time.length == 4 ? '${time.substring(0, 2)}:${time.substring(2)}' : time;
}

/// 一天的分时序列。
class MinuteSeries {
  MinuteSeries({
    required this.symbol,
    required this.name,
    required this.date,
    required this.points,
    required this.prevClose,
  });

  final String symbol;
  final String name;

  /// `20261120`
  final String date;
  final List<MinutePoint> points;

  /// 昨收，用于计算分时涨跌幅与 0 轴位置。
  final double prevClose;

  double get lastPrice => points.isEmpty ? prevClose : points.last.price;

  /// 当前涨跌幅（相对昨收）。
  double get changePct => prevClose == 0 ? 0 : (lastPrice - prevClose) / prevClose * 100;

  /// 全天最大偏离幅度，用于纵轴对称。
  double maxDeviation() {
    var m = 0.0;
    for (final p in points) {
      final d = (p.price - prevClose).abs();
      if (d > m) m = d;
    }
    return m;
  }
}
