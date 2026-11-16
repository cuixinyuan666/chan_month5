/// K线画板：把用户手绘的 1 分钟 K 线聚合为其它周期。
///
/// 2026-11-16 用户明确：左上角操作窗固定 1 分钟 K0；其它窗的 5 分钟应由
/// **5 根** 1 分钟 K 聚合，15 分钟由 **15 根** 1 分钟 K 聚合成，且用户在
/// 下拉里选的其它周期也必须一一对应，不能所有窗都显示同一份 1 分钟数据。
///
/// 画板里每根手绘 K 都对应一个交易分钟（`_advanceTradingMinute` 跳过午休
/// 和非交易时段），所以这里按**连续根数**分组，而不是按自然时间切片：
/// 5 个连续的 1m → 1 根 5m，15 个连续的 1m → 1 根 15m。
library;

import 'dart:math' as math;

import '../models/kline_bar.dart';

/// 各周期对应的 1 分钟 K 根数。
///
/// A 股一个交易日 240 个交易分钟（9:30-11:30 + 13:00-15:00），
/// 日线以上按交易日/周/月折算成连续交易分钟数，保证下拉里任意周期
/// 都能按同一套口径聚合，不再出现「选了周期但数据没变」。
const Map<String, int> kPeriodOneMinuteCounts = <String, int>{
  '1m': 1,
  '5m': 5,
  '15m': 15,
  '30m': 30,
  '60m': 60,
  '2h': 120,
  '4h': 240,
  '1d': 240,
  '3d': 720,
  '1w': 1200,
  '1mon': 4800,
  '3mon': 14400,
  '6mon': 28800,
  '9mon': 43200,
  '12mon': 57600,
  '1y': 57600,
  '3y': 172800,
  '6y': 345600,
};

/// 目标周期需要多少根 1 分钟 K；未知周期按 1 根（原样返回）。
int oneMinuteCountForPeriod(String period) =>
    kPeriodOneMinuteCounts[period] ?? 1;

/// 把 1 分钟 K 列表按 [period] 聚合。
///
/// - 开 = 组内第一根的开，收 = 组内最后一根的收；
/// - 高 = 组内最高，低 = 组内最低（OHLC 口径）；
/// - 成交量/额累加；末尾不足一组时按已有的根数照样出一根（构建中）。
/// - 1m / 未知周期直接原样返回（不复制）。
List<KlineBar> aggregateKlineBarsByPeriod(
  List<KlineBar> oneMinuteBars,
  String period,
) {
  final n = oneMinuteCountForPeriod(period);
  if (n <= 1 || oneMinuteBars.isEmpty) return oneMinuteBars;

  final out = <KlineBar>[];
  for (var i = 0; i < oneMinuteBars.length; i += n) {
    final end = math.min(i + n, oneMinuteBars.length);
    final chunk = oneMinuteBars.sublist(i, end);
    var high = chunk.first.high;
    var low = chunk.first.low;
    var volume = 0.0;
    var amount = 0.0;
    for (final b in chunk) {
      high = math.max(high, b.high);
      low = math.min(low, b.low);
      volume += b.volume;
      amount += b.amount;
    }
    final last = chunk.last;
    out.add(KlineBar(
      idx: out.length,
      timeMs: last.timeMs,
      timeText: last.timeText,
      open: chunk.first.open,
      high: high,
      low: low,
      close: last.close,
      volume: volume,
      amount: amount,
    ));
  }
  return out;
}
