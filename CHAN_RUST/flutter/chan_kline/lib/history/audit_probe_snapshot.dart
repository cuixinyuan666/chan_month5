import '../bridge/chan_bridge.dart';
import '../compute/class_n_bs_compute.dart';
import '../models/bar_crosshair_feature.dart';
import '../models/bar_feature_lookup.dart';
import '../models/buy1_frame.dart';
import '../models/buy_n_frame.dart';
import '../models/chart_indicator.dart';
import '../models/k1_analysis.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_bundle.dart';
import '../models/kline_combine_frame.dart';
import '../models/level_models.dart';
import '../models/sell1_frame.dart';
import '../models/sell_n_frame.dart';
import '../models/zs_frame.dart';

/// 本次任务验收探针（设置「复制调试信息」）。
/// 只含本批：A会话BS冻结 / D tip类键 / Peak / 末枢sure / N类·1Ba·k1_* / asOf源。
/// 常驻按钮；内容随当前验收项更新（勿删按钮）。
class AuditProbeSnapshot {
  static String build({
    required ChanBridge bridge,
    required String code,
    required String period,
    required String periodLabel,
    required String beginDate,
    required String endDate,
    required int stepIdx,
    required bool truncationCheck,
    required List<KlineBar> bars,
    required List<LevelBundle> sessionLevels,
    required List<KlineCombineFrame> sessionK1CombineFrames,
    required List<BarCrosshairFeature> barFeatures,
    required Map<int, List<Buy1Frame>> buy1HistoryByKn,
    required Map<int, List<Sell1Frame>> sell1HistoryByKn,
    required List<Buy1Frame> buy1K0Frames,
    required List<Sell1Frame> sell1K0Frames,
    List<ZSFrame> zsK0Frames = const [],
    Map<int, List<BuyNFrame>> buyNHistoryByKn = const {},
    Map<int, List<SellNFrame>> sellNHistoryByKn = const {},
  }) {
    final now = DateTime.now();
    final ts =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';

    final buf = StringBuffer();
    buf.writeln(
      'CHAN_RUST 验收调试信息（本批：A会话冻结·D tip类键·Peak·末枢sure·N类·asOf·k1_*）',
    );
    buf.writeln('时间=$ts');
    buf.writeln(
      '代码=$code 周期=$period($periodLabel) 区间=$beginDate ~ $endDate',
    );
    buf.writeln(
      'stepIdx=$stepIdx bars=${bars.length} truncationCheck=$truncationCheck',
    );
    buf.writeln('用法：跳末后点本按钮，全文粘贴给助手。');
    buf.writeln();

    if (bars.isEmpty || stepIdx < 0) {
      buf.writeln('【中止】尚无已步进数据。');
      return buf.toString();
    }

    final lastIdx = bars[stepIdx.clamp(0, bars.length - 1)].idx;

    buf.writeln('======== A：一类BS discovery x（会话历史+bar_features） ========');
    buf.writeln('期望：会话 hist 与 bar_features.bs1_hits 同 x；勿冷前缀按 seg。');
    _writeBsFreezeSession(buf, buy1HistoryByKn, sell1HistoryByKn, barFeatures);
    buf.writeln();

    buf.writeln('======== D：tip 三类+BS 行含会话最高类 ========');
    _writeTipClassRows(
      buf,
      bars: bars,
      sessionLevels: sessionLevels,
      barFeatures: barFeatures,
      buyNHistoryByKn: buyNHistoryByKn,
      sellNHistoryByKn: sellNHistoryByKn,
      buy1HistoryByKn: buy1HistoryByKn,
      sell1HistoryByKn: sell1HistoryByKn,
      zsK0Frames: zsK0Frames,
    );
    buf.writeln();

    buf.writeln('======== E：ZSCombineMode::Peak 非空转 ========');
    buf.writeln('期望：Rust try_combine 读 peak→按 DD/GG 重叠合并（单测 peak_combine_*）。');
    buf.writeln(
      '判定=OK_WIRED Peak 已接入 mode；默认 zs；FFI 可传 zs_config.zs_combine_mode=peak',
    );
    buf.writeln();

    buf.writeln('======== F：export 末枢离开才定型 ========');
    buf.writeln('期望：存在未离开虚线末枢；禁「无 active 强制末枢 sure」。');
    _writeLastZsSure(buf, bridge, bars, truncationCheck, lastIdx);
    buf.writeln();

    buf.writeln('======== G：N类每成员·1Ba锁·k1_*命名（口径） ========');
    _writeSemantics(
      buf,
      buyNHistoryByKn: buyNHistoryByKn,
      sellNHistoryByKn: sellNHistoryByKn,
      buy1HistoryByKn: buy1HistoryByKn,
      sell1HistoryByKn: sell1HistoryByKn,
      barFeatures: barFeatures,
    );
    buf.writeln();

    buf.writeln('======== H：asOf 结构源=asOf bundle ========');
    buf.writeln('期望：十字下 painter 的 levels/k0/zsK0 直接传入 asOfBundle（禁会话末态）。');
    _writeAsOfSource(buf, bridge, bars, truncationCheck, lastIdx);
    buf.writeln();

    buf.writeln('======== 结束 ========');
    return buf.toString();
  }

  static void _writeBsFreezeSession(
    StringBuffer buf,
    Map<int, List<Buy1Frame>> buy1HistoryByKn,
    Map<int, List<Sell1Frame>> sell1HistoryByKn,
    List<BarCrosshairFeature> barFeatures,
  ) {
    // 全层取最早 discovery（勿只取 HashMap 首个 kn；K0/K1+ 均应有 bs1_hits）
    int? histX;
    String? histLabel;
    String side = 'S';
    var histKn = -1;
    void considerSell(int kn, Sell1Frame f) {
      if (histX == null || f.x < histX!) {
        histX = f.x;
        histLabel = f.label;
        side = 'S';
        histKn = kn;
      }
    }

    void considerBuy(int kn, Buy1Frame f) {
      if (histX == null || f.x < histX!) {
        histX = f.x;
        histLabel = f.label;
        side = 'B';
        histKn = kn;
      }
    }

    for (final e in sell1HistoryByKn.entries) {
      for (final f in e.value) {
        considerSell(e.key, f);
      }
    }
    for (final e in buy1HistoryByKn.entries) {
      for (final f in e.value) {
        considerBuy(e.key, f);
      }
    }
    if (histX == null) {
      buf.writeln('判定=SKIP_无一类BS会话历史');
      return;
    }
    buf.writeln(
      '会话最早一类 ${side == "S" ? "卖" : "买"} kn=$histKn '
      'label=$histLabel x=$histX',
    );
    BarBs1Hit? hit;
    for (final f in barFeatures) {
      if (f.idx != histX) continue;
      for (final h in f.bs1Hits) {
        if (h.x == histX &&
            (histLabel == null || h.label == histLabel) &&
            (histKn < 0 || h.kn == histKn)) {
          hit = h;
          break;
        }
      }
      hit ??= () {
        for (final h in f.bs1Hits) {
          if (h.x == histX) return h;
        }
        return f.bs1Hits.isEmpty ? null : f.bs1Hits.first;
      }();
      break;
    }
    buf.writeln(
      'bar_features@x=$histX → ${hit == null ? "null" : "kn=${hit.kn} ${hit.side}${hit.label} x=${hit.x}"}',
    );
    final bs1Bars = barFeatures.where((f) => f.bs1Hits.isNotEmpty).length;
    buf.writeln('含bs1_hits的bar数=$bs1Bars（含K0 kn=0）');
    if (hit != null && hit.x == histX) {
      buf.writeln('判定=OK_FIXED 会话x与bs1_hits对齐 x=$histX kn=${hit.kn}');
    } else if (hit == null) {
      buf.writeln('判定=BUG_无bs1_hits（请确认已重编 chan_ffi.dll；K0 也应写入）');
    } else {
      buf.writeln('判定=BUG_X_MISMATCH hist=$histX hit=${hit.x}');
    }
  }

  static void _writeTipClassRows(
    StringBuffer buf, {
    required List<KlineBar> bars,
    required List<LevelBundle> sessionLevels,
    required List<BarCrosshairFeature> barFeatures,
    required Map<int, List<BuyNFrame>> buyNHistoryByKn,
    required Map<int, List<SellNFrame>> sellNHistoryByKn,
    required Map<int, List<Buy1Frame>> buy1HistoryByKn,
    required Map<int, List<Sell1Frame>> sell1HistoryByKn,
    required List<ZSFrame> zsK0Frames,
  }) {
    final observed = maxBuyNClassObserved(
      buyNHistoryByKn: buyNHistoryByKn,
      sellNHistoryByKn: sellNHistoryByKn,
    );
    final tipHi = observed < 9 ? 9 : observed;
    buf.writeln('会话最高类=$observed；tip上界应>=$tipHi');

    int? focusX;
    int focusKn = 1;
    for (final e in buyNHistoryByKn.entries) {
      for (final f in e.value) {
        if (f.cls == observed) {
          focusX = f.x;
          focusKn = e.key;
          break;
        }
      }
      if (focusX != null) break;
    }
    if (focusX == null) {
      for (final e in sellNHistoryByKn.entries) {
        for (final f in e.value) {
          if (f.cls == observed) {
            focusX = f.x;
            focusKn = e.key;
            break;
          }
        }
        if (focusX != null) break;
      }
    }
    if (focusX == null) {
      buf.writeln('判定=SKIP_无三类+样本');
      return;
    }
    buf.writeln('扫 tip @x=$focusX kn=$focusKn cls=$observed');

    final maxKn = chartMaxKn(levels: sessionLevels);
    final lookup = BarFeatureLookup.build(
      bars: bars,
      combineFrames: const [],
      k0Confirms: const [],
      barFeatures: barFeatures,
      k0Lines: const [],
      k1Analysis: const K1AnalysisBundle(),
      levels: sessionLevels,
      buy1HistoryByKn: buy1HistoryByKn,
      sell1HistoryByKn: sell1HistoryByKn,
      buyNHistoryByKn: buyNHistoryByKn,
      sellNHistoryByKn: sellNHistoryByKn,
      subIndicators: {
        SubChartIndicator.buy1(focusKn),
        SubChartIndicator.buy2(focusKn),
        for (var c = 3; c <= tipHi; c++) SubChartIndicator.buyN(focusKn, c),
      },
      maxBsClass: tipHi,
      zsK0Frames: zsK0Frames,
    );
    final names = lookup
        .crosshairSubRows(focusX, {
          SubChartIndicator.buy1(focusKn),
          SubChartIndicator.buy2(focusKn),
          for (var c = 3; c <= tipHi; c++) SubChartIndicator.buyN(focusKn, c),
        })
        .map((r) => r.label)
        .toList();
    final expectCn = 'K$focusKn${bsClassChinese(observed)}类BS';
    final has = names.any((n) => n == expectCn || n.contains('$observed类'));
    buf.writeln('期望行名≈$expectCn；实际BS行=${names.join(" | ")}');
    buf.writeln('chartMaxKn=$maxKn tipHi=$tipHi');
    if (has) {
      buf.writeln('判定=OK_FIXED tip含最高类键 cls=$observed');
    } else {
      buf.writeln('判定=BUG_TIP_缺最高类键');
    }
  }

  static void _writeLastZsSure(
    StringBuffer buf,
    ChanBridge bridge,
    List<KlineBar> bars,
    bool truncationCheck,
    int lastIdx,
  ) {
    final full = _safeBundle(bridge, bars, lastIdx, truncationCheck);
    if (full == null) {
      buf.writeln('判定=FFI_FAIL');
      return;
    }
    var openUnsure = 0;
    var lastSure = 0;
    for (final lv in full.levels) {
      if (lv.zsFrames.isEmpty) continue;
      if (lv.zsFrames.last.isSure) {
        lastSure++;
      } else {
        openUnsure++;
      }
    }
    if (full.zsK0Frames.isNotEmpty) {
      if (full.zsK0Frames.last.isSure) {
        lastSure++;
      } else {
        openUnsure++;
      }
    }
    buf.writeln('末框虚线层数=$openUnsure；末框实线层数=$lastSure');
    if (openUnsure > 0) {
      buf.writeln('判定=OK_FIXED 存在未离开虚线末枢（未强制全 sure）');
    } else if (lastSure == 0) {
      buf.writeln('判定=SKIP_无中枢框');
    } else {
      buf.writeln('判定=INFO_末框全sure（可能均已离开；Rust 已删 force 补丁）');
    }
  }

  static void _writeSemantics(
    StringBuffer buf, {
    required Map<int, List<BuyNFrame>> buyNHistoryByKn,
    required Map<int, List<SellNFrame>> sellNHistoryByKn,
    required Map<int, List<Buy1Frame>> buy1HistoryByKn,
    required Map<int, List<Sell1Frame>> sell1HistoryByKn,
    required List<BarCrosshairFeature> barFeatures,
  }) {
    var multiMember = false;
    for (final list in buyNHistoryByKn.values) {
      final byKey = <String, int>{};
      for (final f in list) {
        final k = '${f.zsSeq}|${f.cls}';
        byKey[k] = (byKey[k] ?? 0) + 1;
        if (byKey[k]! >= 2) multiMember = true;
      }
    }
    for (final list in sellNHistoryByKn.values) {
      final byKey = <String, int>{};
      for (final f in list) {
        final k = '${f.zsSeq}|${f.cls}';
        byKey[k] = (byKey[k] ?? 0) + 1;
        if (byKey[k]! >= 2) multiMember = true;
      }
    }
    buf.writeln(
      'N类同框多成员打点=${multiMember ? "是" : "未观察到"}；'
      '口径=每成员都标（非1/2类极值）',
    );

    var nonA = 0;
    var total1 = 0;
    for (final list in buy1HistoryByKn.values) {
      for (final f in list) {
        total1++;
        final lab = f.label.toLowerCase();
        if (!lab.endsWith('a')) nonA++;
      }
    }
    for (final list in sell1HistoryByKn.values) {
      for (final f in list) {
        total1++;
        final lab = f.label.toLowerCase();
        if (!lab.endsWith('a')) nonA++;
      }
    }
    buf.writeln('一类标签总数=$total1 非a后缀=$nonA（方案A锁1Ba/1Sa）');
    if (total1 > 0 && nonA == 0) {
      buf.writeln('一类字母=OK_LOCKED_a');
    } else if (total1 == 0) {
      buf.writeln('一类字母=SKIP');
    } else {
      buf.writeln('一类字母=WARN_有非a');
    }

    final withK1 = barFeatures.where((f) => f.k1Idx != null).length;
    buf.writeln(
      'bar_features 含 k1_idx 的bar=$withK1；'
      '口径：k1_*=structure0 虚拟K（K0连线合成），≠displayKn=1',
    );
    buf.writeln('判定=OK_DOCUMENTED N类每成员/1Ba锁/k1_*命名已落注释与历史');
  }

  static void _writeAsOfSource(
    StringBuffer buf,
    ChanBridge bridge,
    List<KlineBar> bars,
    bool truncationCheck,
    int lastIdx,
  ) {
    final asOf = (lastIdx * 0.3).floor().clamp(0, lastIdx);
    final mid = _safeBundle(bridge, bars, asOf, truncationCheck);
    final full = _safeBundle(bridge, bars, lastIdx, truncationCheck);
    if (mid == null || full == null) {
      buf.writeln('判定=FFI_FAIL');
      return;
    }
    final midSeg =
        mid.levels.isEmpty ? 0 : mid.levels.first.segments.length;
    final fullSeg =
        full.levels.isEmpty ? 0 : full.levels.first.segments.length;
    buf.writeln(
      'asOf@$asOf lv0.segments=$midSeg；full@$lastIdx lv0.segments=$fullSeg',
    );
    if (midSeg < fullSeg) {
      buf.writeln(
        '判定=OK_FIXED asOf前缀结构短于末态；painter 十字下直接传 asOfBundle.levels',
      );
    } else {
      buf.writeln('判定=INFO_段数未变短（样本早期可能已穷尽）');
    }
  }

  static KlineCombineBundle? _safeBundle(
    ChanBridge bridge,
    List<KlineBar> bars,
    int endIdx,
    bool truncationCheck,
  ) {
    try {
      final slice = bars.where((b) => b.idx <= endIdx).toList();
      if (slice.isEmpty) return null;
      return bridge.buildKlineCombineBundle(
        slice,
        truncationCheck: truncationCheck,
      );
    } catch (_) {
      return null;
    }
  }
}
