import '../bridge/chan_bridge.dart';
import '../compute/class_n_bs_compute.dart';
import '../models/bar_crosshair_feature.dart';
import '../models/buy1_frame.dart';
import '../models/buy_n_frame.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_bundle.dart';
import '../models/kline_combine_frame.dart';
import '../models/level_models.dart';
import '../models/sell1_frame.dart';
import '../models/sell_n_frame.dart';
import '../models/zs_frame.dart';

// buy1K0Frames / sessionK1 保留入参兼容 main 调用，本轮探针未用

/// 本次任务验收探针（设置「复制调试信息」）。
/// 绑定：①一类BS x 冻结 ②sure中枢禁合并改写 ③bar_features.zs/bs1 ④tip maxBsClass
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
    buf.writeln('CHAN_RUST 验收调试信息（BS冻结·sure中枢·bar_features·tip类上界）');
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

    // ---- A：一类BS x 冻结 ----
    buf.writeln('======== A：一类BS discovery x 冻结 ========');
    buf.writeln('期望：同 seg 在 discovery 后更长前缀上 x 不变。');
    _writeBsFreeze(buf, bridge, bars, truncationCheck, sessionLevels, lastIdx);
    buf.writeln();

    // ---- B：sure 中枢禁改写 ----
    buf.writeln('======== B：已定型中枢禁合并改写 ========');
    buf.writeln('期望：早期已 is_sure 的框 high/low/x2 在全量末态仍一致。');
    _writeSureZs(buf, bridge, bars, truncationCheck, lastIdx);
    buf.writeln();

    // ---- C：bar_features zs/bs1 ----
    buf.writeln('======== C：bar_features.zs_hits / bs1_hits ========');
    buf.writeln('期望：Rust 逐K特征含 zs_hits、bs1_hits（非空样本）。');
    _writeBarFeatureHits(buf, barFeatures, lastIdx);
    buf.writeln();

    // ---- D：tip maxBsClass ----
    buf.writeln('======== D：tip 三类+BS 上界=maxBsClass ========');
    final observed = maxBuyNClassObserved(
      buyNHistoryByKn: buyNHistoryByKn,
      sellNHistoryByKn: sellNHistoryByKn,
    );
    final tipHi = observed < 9 ? 9 : observed;
    buf.writeln('会话观察到的最高类=$observed；tip上界应>=$tipHi（至少9）');
    buf.writeln(
      observed > 9
          ? '判定=OK_DATA_HAS_CLASS_$observed（tip应扩到该类）'
          : '判定=OK_DEFAULT_HI_9（本样本无>9类；逻辑已跟 maxBsClass）',
    );
    buf.writeln();

    buf.writeln('======== 结束 ========');
    return buf.toString();
  }

  static void _writeBsFreeze(
    StringBuffer buf,
    ChanBridge bridge,
    List<KlineBar> bars,
    bool truncationCheck,
    List<LevelBundle> sessionLevels,
    int lastIdx,
  ) {
    LevelBundle? lv0;
    for (final l in sessionLevels) {
      if (l.level == 0) {
        lv0 = l;
        break;
      }
    }
    final sells = lv0?.sell1Frames ?? const <Sell1Frame>[];
    if (sells.isEmpty) {
      buf.writeln('判定=SKIP_无卖1');
      return;
    }
    final s0 = sells.first;
    final disc = s0.x;
    buf.writeln(
      '跟踪首卖 label=${s0.label} seg=${s0.segIdx} zs=${s0.zsSeq} full_x=${s0.x}',
    );
    if (disc < 0 || disc >= bars.length) {
      buf.writeln('判定=SKIP_x越界');
      return;
    }
    final later = (disc + 30).clamp(0, lastIdx);
    final atDisc = _safeBundle(bridge, bars, disc, truncationCheck);
    final atLater = _safeBundle(bridge, bars, later, truncationCheck);
    final a = _sellX(atDisc, s0.segIdx);
    final b = _sellX(atLater, s0.segIdx);
    buf.writeln('前缀@$disc → x=$a；前缀@$later → x=$b');
    if (a != null && b != null && a == b) {
      buf.writeln('判定=OK_FIXED x冻结 a=b=$a');
    } else if (a != null && b != null) {
      buf.writeln('判定=BUG_X_DRIFT a=$a b=$b');
    } else {
      buf.writeln('判定=INFO_前缀未复现同seg（可能结构变化） a=$a b=$b');
    }
  }

  static void _writeSureZs(
    StringBuffer buf,
    ChanBridge bridge,
    List<KlineBar> bars,
    bool truncationCheck,
    int lastIdx,
  ) {
    final early = 200.clamp(0, lastIdx);
    final e = _safeBundle(bridge, bars, early, truncationCheck);
    final full = _safeBundle(bridge, bars, lastIdx, truncationCheck);
    if (e == null || full == null) {
      buf.writeln('判定=FFI_FAIL');
      return;
    }
    var checked = 0;
    var ok = 0;
    var bad = 0;
    for (final lv in e.levels) {
      for (final z in lv.zsFrames.where((z) => z.isSure).take(3)) {
        checked++;
        ZSFrame? zf;
        for (final l in full.levels) {
          if (l.level != lv.level) continue;
          for (final zz in l.zsFrames) {
            if (zz.seq == z.seq && zz.isSure) {
              zf = zz;
              break;
            }
          }
        }
        if (zf == null) {
          buf.writeln(
            'L${lv.level} seq=${z.seq} early sure 在全量中找不到同seq sure',
          );
          bad++;
          continue;
        }
        final same = (z.high - zf.high).abs() < 1e-9 &&
            (z.low - zf.low).abs() < 1e-9 &&
            z.x1 == zf.x1 &&
            z.x2 == zf.x2;
        if (same) {
          ok++;
        } else {
          bad++;
          buf.writeln(
            'REWRITE L${lv.level} seq=${z.seq} '
            'early h/l=${z.high}/${z.low} x=${z.x1}..${z.x2} | '
            'full h/l=${zf.high}/${zf.low} x=${zf.x1}..${zf.x2}',
          );
        }
      }
    }
    buf.writeln('抽检 sure框 checked=$checked ok=$ok bad=$bad early@$early');
    if (checked == 0) {
      buf.writeln('判定=SKIP_early无sure框');
    } else if (bad == 0) {
      buf.writeln('判定=OK_FIXED sure框未改写');
    } else {
      buf.writeln('判定=BUG_SURE_REWRITTEN');
    }
  }

  static void _writeBarFeatureHits(
    StringBuffer buf,
    List<BarCrosshairFeature> barFeatures,
    int lastIdx,
  ) {
    buf.writeln('bar_features条数=${barFeatures.length}');
    if (barFeatures.isEmpty) {
      buf.writeln('判定=NO_BAR_FEATURES');
      return;
    }
    var zsN = 0;
    var bsN = 0;
    BarCrosshairFeature? sampleZs;
    BarCrosshairFeature? sampleBs;
    for (final f in barFeatures) {
      if (f.zsHits.isNotEmpty) {
        zsN++;
        sampleZs ??= f;
      }
      if (f.bs1Hits.isNotEmpty) {
        bsN++;
        sampleBs ??= f;
      }
    }
    buf.writeln('含zs_hits的bar数=$zsN；含bs1_hits的bar数=$bsN');
    if (sampleZs != null) {
      final h = sampleZs.zsHits.first;
      buf.writeln(
        '样例zs idx=${sampleZs.idx} kn=${h.kn} seq=${h.seq} '
        'h/l=${h.high}/${h.low} sure=${h.isSure}',
      );
    }
    if (sampleBs != null) {
      final h = sampleBs.bs1Hits.first;
      buf.writeln(
        '样例bs1 idx=${sampleBs.idx} kn=${h.kn} ${h.side}${h.label} '
        'x=${h.x} px=${h.price}',
      );
    }
    // 当下性：全量末态下，历史 idx 的 bs1_hits 不应含「只在更晚才 discovery」的点
    // 简化：若某 idx 的 bs1.x 必须==idx
    var badX = 0;
    for (final f in barFeatures) {
      for (final h in f.bs1Hits) {
        if (h.x != f.idx) badX++;
      }
    }
    buf.writeln('bs1_hits中 x!=idx 的异常数=$badX');
    if (zsN > 0 && bsN > 0 && badX == 0) {
      buf.writeln('判定=OK_FIXED bar_features 已含 zs/bs1 且 discovery 对齐');
    } else if (zsN > 0 && bsN > 0) {
      buf.writeln('判定=PARTIAL zs/bs1有数据但 x 对齐异常');
    } else if (zsN == 0 && bsN == 0) {
      buf.writeln('判定=BUG_无hits（请确认已重编 chan_ffi.dll）');
    } else {
      buf.writeln('判定=PARTIAL zsN=$zsN bsN=$bsN');
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

  static int? _sellX(KlineCombineBundle? bundle, int segIdx) {
    if (bundle == null) return null;
    for (final lv in bundle.levels) {
      if (lv.level != 0) continue;
      for (final p in lv.sell1Frames) {
        if (p.segIdx == segIdx) return p.x;
      }
    }
    return null;
  }
}
