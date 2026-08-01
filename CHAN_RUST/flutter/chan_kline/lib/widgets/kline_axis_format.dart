import 'dart:math' as math;

import '../models/kline_bar.dart';

/// X 轴时间标签格式化。
class KlineAxisFormat {
  /// 是否分钟级行情（time_text 含时分）。
  static bool isMinuteLike(Iterable<KlineBar> bars) {
    for (final b in bars) {
      if (b.timeText.contains(':')) return true;
    }
    return false;
  }

  /// 是否含秒（分笔 tick 合成时间）。
  static bool isSecondLike(Iterable<KlineBar> bars) {
    for (final b in bars) {
      final t = b.timeText.trim();
      // YYYY/MM/DD HH:MM:SS → 至少两处冒号
      if (':'.allMatches(t).length >= 2) return true;
    }
    return false;
  }

  /// 对齐 a_replay toDateLabel：分笔→到秒；分钟→到分；日线→日期。
  static String xLabel(String timeText, {required bool minuteLike, bool secondLike = false}) {
    final text = timeText.trim();
    if (text.isEmpty) return '-';
    if (secondLike || (minuteLike && ':'.allMatches(text).length >= 2)) {
      return text.length >= 19 ? text.substring(0, 19) : text;
    }
    if (minuteLike) {
      return text.length >= 16 ? text.substring(0, 16) : text;
    }
    return text.length >= 10 ? text.substring(0, 10) : text;
  }

  /// 视窗内 X 轴刻度间隔（根数），随缩放自动疏密。
  static int xTickInterval(double plotW, double span, String sampleLabel) {
    final approxW = math.max(36.0, sampleLabel.length * 6.2 + 8);
    final perBarPx = plotW / math.max(1, span);
    return math.max(1, (approxW / math.max(1, perBarPx)).ceil());
  }
}
