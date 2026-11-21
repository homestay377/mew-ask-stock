import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/stock/minute.dart';

/// 分时均价线回归。
///
/// 口径就一条：**累计成交额 / 累计成交量**（volume 是「手」，所以乘 100）。
/// 这里锁住三件事：算得对、指数不乱画、量纲不对不硬算。
void main() {
  test('均价 = 累计成交额 / (累计成交量 × 100)', () {
    // 10 元成交 100 手 → 100×100 股 ×10 元 = 100000 元
    // 11 元再成交 100 手 → 累计 200 手、210000 元 → 均价 10.5
    final s = MinuteSeries(
      symbol: 'sz300274',
      name: '测试',
      date: '20261120',
      prevClose: 10,
      points: [
        MinutePoint('0930', 10, 100, 100000),
        MinutePoint('0931', 11, 200, 210000),
        MinutePoint('0932', 12, 200, 210000), // 这一分钟没成交
      ],
    );
    final avg = s.avgPriceSeries();
    expect(avg, isNotNull);
    expect(avg![0], closeTo(10, 1e-9));
    expect(avg[1], closeTo(10.5, 1e-9));
    expect(avg[2], closeTo(10.5, 1e-9), reason: '没成交时均价不变');
  });

  test('成交量为 0 的点返回 null（画线时断开，不画成 0 元）', () {
    final s = MinuteSeries(
      symbol: 'sz300274',
      name: '测试',
      date: '20261120',
      prevClose: 10,
      points: [MinutePoint('0930', 10, 0, 0), MinutePoint('0931', 10, 100, 100000)],
    );
    final avg = s.avgPriceSeries();
    expect(avg, isNotNull);
    expect(avg![0], isNull);
    expect(avg[1], closeTo(10, 1e-9));
  });

  test('指数不画均价线', () {
    // 指数分时的 amount 是成分股成交额，与点位无关：实测算出来是 14，点位是 3533
    for (final sym in ['sh000001', 'sz399001', 'sh000300', 'sh950001']) {
      final s = MinuteSeries(
        symbol: sym,
        name: '指数',
        date: '20261120',
        prevClose: 3500,
        points: [MinutePoint('0930', 3533, 499711727, 702573853115)],
      );
      expect(s.isIndexLike, isTrue, reason: '$sym 应识别为指数');
      expect(s.avgPriceSeries(), isNull, reason: '$sym 不该算均价');
    }
  });

  test('量纲不对（首点均价偏离价格 10% 以上）就不硬算', () {
    final s = MinuteSeries(
      symbol: 'sz300274',
      name: '测试',
      date: '20261120',
      prevClose: 10,
      points: [MinutePoint('0930', 10, 100, 1000000)], // amount 多了 10 倍
    );
    expect(s.avgPriceSeries(), isNull);
  });

  test('ETF 不是指数，照常算均价', () {
    final s = MinuteSeries(
      symbol: 'sh510300',
      name: '沪深300ETF',
      date: '20261120',
      prevClose: 4,
      points: [MinutePoint('0930', 4, 100, 40000)], // 100 手 × 100 股 × 4 元
    );
    final avg = s.avgPriceSeries();
    expect(avg, isNotNull);
    expect(avg!.first, closeTo(4, 1e-9));
  });
}
