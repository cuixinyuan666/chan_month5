import '../bridge/chan_bridge.dart';
import '../models/bar_crosshair_feature.dart';
import '../models/buy1_frame.dart';
import '../models/chart_indicator.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_bundle.dart';
import '../models/kline_combine_frame.dart';
import '../models/level_models.dart';
import '../models/sell1_frame.dart';

/// 审计探针：例1–例5核对字段（设置「复制调试信息」）。
/// 常驻：勿当临时调试代码删；合并 main 时须保留按钮与本文件。
class AuditProbeSnapshot {
  /// 固定探针 idx（分笔默认区间已验证过这些点位）。
  static const probeIdx3 = 3;
  static const probeIdx7 = 7;
  static const probeIdx12 = 12;
  static const probeAsOf100 = 100;

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
  }) {
    final now = DateTime.now();
    final ts =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';

    final buf = StringBuffer();
    buf.writeln('CHAN_RUST 审计调试信息（例1–例5）');
    buf.writeln('时间=$ts');
    buf.writeln(
      '代码=$code 周期=$period($periodLabel) 区间=$beginDate ~ $endDate',
    );
    buf.writeln(
      'stepIdx=$stepIdx bars=${bars.length} truncationCheck=$truncationCheck',
    );
    buf.writeln(
      '用法：默认002003+分笔+默认区间；建议一键跳末后再点本按钮；'
      '把全文粘贴给助手核对猜想。',
    );
    buf.writeln();

    if (bars.isEmpty || stepIdx < 0) {
      buf.writeln('【中止】尚无已步进数据（先加载并至少单步/跳末）。');
      return buf.toString();
    }

    final lastIdx = bars[stepIdx.clamp(0, bars.length - 1)].idx;
    final sessionBundle = _SessionView(
      levels: sessionLevels,
      k1CombineFrames: sessionK1CombineFrames,
      barFeatures: barFeatures,
      buy1K0: buy1K0Frames,
      sell1K0: sell1K0Frames,
    );

    // ---- 例1：K1合并 tip 层号 vs 主图 ----
    buf.writeln('======== 例1：K1合并 tip/主图是否同框 ========');
    buf.writeln(
      '猜想：tip 的 combine_box_1 误取 structure.level==0（K0合并），'
      '主图 K1合并取 k1CombineFrames / level==1。',
    );
    _writeEx1At(
      buf,
      bridge: bridge,
      bars: bars,
      truncationCheck: truncationCheck,
      prefixEnd: probeIdx3,
      focus: probeIdx3,
      note: '当下前缀=3（第一根K1未确认：两边都应无K1合并）',
    );
    _writeEx1At(
      buf,
      bridge: bridge,
      bars: bars,
      truncationCheck: truncationCheck,
      prefixEnd: probeIdx7,
      focus: probeIdx7,
      note: '第一根K1刚出现（约10:51）',
    );
    _writeEx1At(
      buf,
      bridge: bridge,
      bars: bars,
      truncationCheck: truncationCheck,
      prefixEnd: probeIdx12,
      focus: probeIdx12,
      note: '主验收点：主图宽框 vs tip 是否张冠李戴',
    );
    buf.writeln();

    // ---- 例2：asOf 双轨 ----
    buf.writeln('======== 例2：十字 asOf 与会话末态计数 ========');
    buf.writeln(
      '说明：正常十字下 K0/K1合并已走 asOf 重算，肉眼常看不到「铺满未来」。'
      '本段比「会话已喂到 lastIdx」与「只喂到100」的结构计数；'
      '并标明 painter featureLookup 仍有 `zsAsOfBundle?.levels ?? levels` 回落点。',
    );
    _writeEx2(
      buf,
      bridge: bridge,
      bars: bars,
      truncationCheck: truncationCheck,
      lastIdx: lastIdx,
      session: sessionBundle,
    );
    buf.writeln();

    // ---- 例3：一类BS x / 会话冻结 ----
    buf.writeln('======== 例3：一类BS 打点x 与会话历史 ========');
    buf.writeln(
      '猜想：Rust 导出可能随 active 右端漂移；Flutter 会话双键应钉住 discoveryX。',
    );
    _writeEx3(
      buf,
      bridge: bridge,
      bars: bars,
      truncationCheck: truncationCheck,
      lastIdx: lastIdx,
      session: sessionBundle,
      buy1HistoryByKn: buy1HistoryByKn,
      sell1HistoryByKn: sell1HistoryByKn,
    );
    buf.writeln();

    // ---- 例4：三型/四型特征上界 ----
    buf.writeln('======== 例4：三型/四型 tip 层上界 ========');
    buf.writeln(
      '猜想：bar_feature_lookup 用 maxD=structureMax-1，缺最高连线层。',
    );
    _writeEx4(buf, sessionLevels: sessionLevels);
    buf.writeln();

    // ---- 例5：ML bar_features 是否含 zs/BS ----
    buf.writeln('======== 例5：bar_features 与主副图 BS/中枢是否同源 ========');
    buf.writeln(
      '猜想：Rust BarCrosshairFeature 无 zs/一类BS 字段；主副图来自 bundle 帧+会话历史。',
    );
    _writeEx5(buf, session: sessionBundle, lastIdx: lastIdx);
    buf.writeln();
    buf.writeln('======== 结束 ========');
    return buf.toString();
  }

  static void _writeEx1At(
    StringBuffer buf, {
    required ChanBridge bridge,
    required List<KlineBar> bars,
    required bool truncationCheck,
    required int prefixEnd,
    required int focus,
    required String note,
  }) {
    buf.writeln('--- focus=$focus prefixEnd=$prefixEnd | $note ---');
    if (prefixEnd >= bars.length) {
      buf.writeln('跳过：bars不足 prefixEnd=$prefixEnd bars=${bars.length}');
      return;
    }
    final bundle = _safeBundle(bridge, bars, prefixEnd, truncationCheck);
    if (bundle == null) {
      buf.writeln('FFI失败：无法重建 prefix<=$prefixEnd');
      return;
    }
    final lv0 = _levelAt(bundle.levels, 0);
    final lv1 = _levelAt(bundle.levels, 1);
    final k1Bars = bundle.k1Bars.length;
    final conf = bundle.k0Confirms.length;
    final wrong = _frameCovering(lv0?.combineFrames ?? const [], focus);
    final right = _frameCovering(lv1?.combineFrames ?? const [], focus);
    final main = _frameCovering(bundle.k1CombineFrames, focus);
    final tipK0 = _frameCovering(bundle.frames, focus);

    buf.writeln(
      'k0_confirms=$conf k1_bars=$k1Bars '
      'lv0_cf=${lv0?.combineFrames.length ?? 0} '
      'lv1_cf=${lv1?.combineFrames.length ?? 0} '
      'k1_cf=${bundle.k1CombineFrames.length}',
    );
    buf.writeln('main_K1合并(k1CombineFrames@focus)=${_fmtFrame(main)}');
    buf.writeln(
      'tip_K1合并_现行模拟(combine_box_1←level+1即lv0)=${_fmtFrame(wrong)}',
    );
    buf.writeln(
      'tip_K1合并_方案B应取(level==1)=${_fmtFrame(right)}',
    );
    buf.writeln('tip_K0合并(frames@focus)=${_fmtFrame(tipK0)}');

    final verdict = _ex1Verdict(
      prefixEnd: prefixEnd,
      focus: focus,
      k1Bars: k1Bars,
      main: main,
      wrong: wrong,
      right: right,
    );
    buf.writeln('判定=$verdict');
  }

  static String _ex1Verdict({
    required int prefixEnd,
    required int focus,
    required int k1Bars,
    required KlineCombineFrame? main,
    required KlineCombineFrame? wrong,
    required KlineCombineFrame? right,
  }) {
    if (prefixEnd <= probeIdx3 && k1Bars == 0) {
      if (main == null && right == null) {
        return 'OK_当下无K1（符合设计）';
      }
      return '异常_prefix<=3仍见K1合并';
    }
    if (main == null) {
      return 'INFO_主图该focus无K1合并框（可能在框外/构建中未盖住）';
    }
    if (_sameBox(main, wrong) && !_sameBox(main, right)) {
      return 'BUG_CONFIRMED tip现行=主图却来自lv0映射（或主图与错误源偶然同值）';
    }
    if (_sameBox(main, right) && !_sameBox(main, wrong)) {
      return 'BUG_CONFIRMED tip现行(lv0)≠主图；方案B(lv1)=主图 → 层号张冠李戴';
    }
    if (_sameBox(main, right) && _sameBox(main, wrong)) {
      return 'INFO_三源同值（此focus分不出层号bug）';
    }
    if (!_sameBox(main, wrong) && right == null) {
      return 'BUG_LIKELY tip现行≠主图，且lv1无盖住focus的框（主图走k1_cf展示轨）';
    }
    return 'INFO_需人工看三行框体';
  }

  static void _writeEx2(
    StringBuffer buf, {
    required ChanBridge bridge,
    required List<KlineBar> bars,
    required bool truncationCheck,
    required int lastIdx,
    required _SessionView session,
  }) {
    final asOf = probeAsOf100;
    buf.writeln('会话末(lastIdx=$lastIdx)结构计数：');
    _writeLevelCounts(buf, 'session', session.levels, session.k1CombineFrames);

    if (asOf > lastIdx) {
      buf.writeln(
        '跳过asOf=$asOf前缀：当前step只到$lastIdx（请跳末或单步到>=$asOf后再复制）',
      );
      buf.writeln('判定=SKIP_步进不足');
      return;
    }
    if (asOf >= bars.length) {
      buf.writeln('跳过：bars不足 asOf=$asOf');
      return;
    }

    final asOfBundle = _safeBundle(bridge, bars, asOf, truncationCheck);
    if (asOfBundle == null) {
      buf.writeln('asOf=$asOf FFI失败 → tip会空；painter featureLookup 可能回落会话末态');
      buf.writeln('判定=ASOF_FFI_FAIL（此情形才容易肉眼看到例2）');
      return;
    }

    final t = bars[asOf].timeText;
    buf.writeln('asOf=$asOf t=$t 前缀重算计数：');
    _writeLevelCounts(buf, 'asOf', asOfBundle.levels, asOfBundle.k1CombineFrames);

    final s0 = _levelAt(session.levels, 0)?.combineFrames.length ?? 0;
    final a0 = _levelAt(asOfBundle.levels, 0)?.combineFrames.length ?? 0;
    final s1 = session.k1CombineFrames.length;
    final a1 = asOfBundle.k1CombineFrames.length;
    buf.writeln(
      '差值：lv0_cf session-asOf=${s0 - a0}；k1_cf session-asOf=${s1 - a1}',
    );
    buf.writeln(
      '代码路径：'
      'tip.levels=asOfBundle??[]（禁回落）；'
      '主图K0/K1合并=_effective*（asOf重算）；'
      'painter.BarFeatureLookup.levels=zsAsOfBundle?.levels??sessionLevels（有回落）。',
    );
    if (s0 > a0 || s1 > a1) {
      buf.writeln(
        '判定=DATA_DIFF_OK（末态多于asOf100，属预期；'
        '正常十字合并已asOf，故你常看不到铺满未来）',
      );
    } else {
      buf.writeln('判定=NO_COUNT_DIFF');
    }
  }

  static void _writeEx3(
    StringBuffer buf, {
    required ChanBridge bridge,
    required List<KlineBar> bars,
    required bool truncationCheck,
    required int lastIdx,
    required _SessionView session,
    required Map<int, List<Buy1Frame>> buy1HistoryByKn,
    required Map<int, List<Sell1Frame>> sell1HistoryByKn,
  }) {
    // 显示层 K1一类 = structure level0；history 键 display=1
    final rustLv0 = _levelAt(session.levels, 0);
    final rustSell = rustLv0?.sell1Frames ?? const <Sell1Frame>[];
    final rustBuy = rustLv0?.buy1Frames ?? const <Buy1Frame>[];
    final histSell = sell1HistoryByKn[1] ?? const <Sell1Frame>[];
    final histBuy = buy1HistoryByKn[1] ?? const <Buy1Frame>[];

    buf.writeln(
      'session structure.level0：buy1=${rustBuy.length} sell1=${rustSell.length}',
    );
    buf.writeln(
      '会话历史 displayKn=1：buy1=${histBuy.length} sell1=${histSell.length}',
    );
    buf.writeln('K0一类：buy1=${session.buy1K0.length} sell1=${session.sell1K0.length}');

    void dumpSell(String tag, List<Sell1Frame> list, {int n = 3}) {
      for (final s in list.take(n)) {
        buf.writeln(
          '$tag 1S label=${s.label} x=${s.x} price=${s.price} '
          'seg=${s.segIdx} zs=${s.zsSeq} level=${s.level}',
        );
      }
    }

    void dumpBuy(String tag, List<Buy1Frame> list, {int n = 3}) {
      for (final b in list.take(n)) {
        buf.writeln(
          '$tag 1B label=${b.label} x=${b.x} price=${b.price} '
          'seg=${b.segIdx} zs=${b.zsSeq} level=${b.level}',
        );
      }
    }

    dumpSell('rust', rustSell);
    dumpSell('hist', histSell);
    dumpBuy('rust', rustBuy);
    dumpBuy('hist', histBuy);

    // 跟踪首个 rust sell1：discovery 前缀 vs 末态 x
    if (rustSell.isNotEmpty) {
      final s0 = rustSell.first;
      final disc = s0.x;
      buf.writeln('跟踪首个rust卖1：label=${s0.label} full_x=${s0.x} seg=${s0.segIdx}');
      if (disc >= 0 && disc < bars.length) {
        final atDisc = _safeBundle(bridge, bars, disc, truncationCheck);
        final later = (disc + 30).clamp(0, lastIdx);
        final atLater = _safeBundle(bridge, bars, later, truncationCheck);
        final a = _sellXAt(
          atDisc,
          segIdx: s0.segIdx,
          zsSeq: s0.zsSeq,
        );
        final b = _sellXAt(
          atLater,
          segIdx: s0.segIdx,
          zsSeq: s0.zsSeq,
        );
        buf.writeln('前缀@$disc → x=$a；前缀@$later → x=$b');
        if (a != null && b != null && a != b) {
          buf.writeln('判定=RUST_X_DRIFT a=$a b=$b');
        } else if (a != null && b != null) {
          buf.writeln('判定=RUST_X_STABLE（本样本首卖未漂）');
        } else {
          buf.writeln('判定=INFO_未在前缀复现同seg卖点');
        }
      }
    } else {
      buf.writeln('判定=NO_SELL1_ON_LV0');
    }

    // hist vs rust 首点 x
    if (histSell.isNotEmpty && rustSell.isNotEmpty) {
      final h0 = histSell.first;
      final r0 = rustSell.first;
      buf.writeln(
        '对照首卖 hist.x=${h0.x} rust.x=${r0.x} '
        '${h0.x == r0.x ? "同x" : "不同x(会话钉死vs末态导出)"}',
      );
    }
  }

  static void _writeEx4(
    StringBuffer buf, {
    required List<LevelBundle> sessionLevels,
  }) {
    var structureMax = -1;
    for (final lv in sessionLevels) {
      if (lv.level > structureMax) structureMax = lv.level;
    }
    final maxKn = chartMaxKn(levels: sessionLevels);
    // 复现 bar_feature_lookup 现行上界
    var maxDBug = 0;
    for (final lv in sessionLevels) {
      final d = lv.level - 1;
      if (d > maxDBug) maxDBug = d;
    }
    final maxDFix = structureMax < 0 ? 0 : structureMax;
    buf.writeln('structureMax=$structureMax chartMaxKn=$maxKn');
    buf.writeln('三型/四型循环上界_现行maxD(level-1)=$maxDBug → dkn=0..$maxDBug');
    buf.writeln('三型/四型循环上界_方案B应取=$maxDFix → dkn=0..$maxDFix');
    if (structureMax >= 0 && maxDBug < maxDFix) {
      buf.writeln(
        '判定=BUG_CONFIRMED 缺最高连线层 displayKn=$maxDFix 的三型/四型特征',
      );
    } else if (structureMax < 1) {
      buf.writeln('判定=SKIP_层数不足');
    } else {
      buf.writeln('判定=NO_GAP');
    }
  }

  static void _writeEx5(
    StringBuffer buf, {
    required _SessionView session,
    required int lastIdx,
  }) {
    final bf = session.barFeatures;
    buf.writeln('bar_features条数=${bf.length}');
    if (bf.isEmpty) {
      buf.writeln('判定=NO_BAR_FEATURES');
      return;
    }
    final sample = bf[lastIdx.clamp(0, bf.length - 1)];
    buf.writeln(
      '样本idx=${sample.idx} 字段='
      'weekday,merge_*,combine_*,fractal_peak_dist,k1_*,levels[] '
      '（无 zs_* / buy1_* / sell1_* 字段）',
    );
    buf.writeln('levels快照层数=${sample.levels.length}');
    for (final s in sample.levels.take(4)) {
      buf.writeln(
        '  snap.level=${s.level} unitIdx=${s.unitIdx} '
        'combineHigh=${s.combineHigh} combineLow=${s.combineLow}',
      );
    }

    var zsOnly = 0;
    var buy1N = session.buy1K0.length;
    var sell1N = session.sell1K0.length;
    for (final lv in session.levels) {
      zsOnly += lv.zsFrames.length;
      buy1N += lv.buy1Frames.length;
      sell1N += lv.sell1Frames.length;
    }
    buf.writeln(
      'bundle可见：levels内zs=$zsOnly buy1合计(含K0帧)=$buy1N '
      'sell1合计(含K0帧)=$sell1N',
    );
    buf.writeln(
      '判定=SCHEMA_GAP bar_features不含zs/BS；'
      '主副图/会话历史另源 → ML若只导bar_features则与画面不同源',
    );
  }

  static void _writeLevelCounts(
    StringBuffer buf,
    String tag,
    List<LevelBundle> levels,
    List<KlineCombineFrame> k1cf,
  ) {
    buf.writeln('$tag k1_combine_frames=${k1cf.length} levels=${levels.length}');
    for (final lv in levels) {
      buf.writeln(
        '  $tag L${lv.level} cf=${lv.combineFrames.length} '
        'zs=${lv.zsFrames.length} buy1=${lv.buy1Frames.length} '
        'sell1=${lv.sell1Frames.length} segs=${lv.segments.length}',
      );
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

  static LevelBundle? _levelAt(List<LevelBundle> levels, int level) {
    for (final lv in levels) {
      if (lv.level == level) return lv;
    }
    return null;
  }

  static KlineCombineFrame? _frameCovering(
    List<KlineCombineFrame> frames,
    int focus,
  ) {
    for (final f in frames) {
      if (f.x1 <= focus && focus <= f.x2) return f;
    }
    return null;
  }

  static String _fmtFrame(KlineCombineFrame? f) {
    if (f == null) return 'null';
    return 'x1=${f.x1} x2=${f.x2} h=${f.high} l=${f.low} fx=${f.fx} count=${f.count}';
  }

  static bool _sameBox(KlineCombineFrame? a, KlineCombineFrame? b) {
    if (a == null || b == null) return false;
    return a.x1 == b.x1 &&
        a.x2 == b.x2 &&
        (a.high - b.high).abs() < 1e-9 &&
        (a.low - b.low).abs() < 1e-9;
  }

  static int? _sellXAt(
    KlineCombineBundle? bundle, {
    required int segIdx,
    required int zsSeq,
  }) {
    if (bundle == null) return null;
    final frames = _levelAt(bundle.levels, 0)?.sell1Frames;
    if (frames == null) return null;
    for (final p in frames) {
      if (p.segIdx == segIdx && p.zsSeq == zsSeq) return p.x;
    }
    return null;
  }
}

class _SessionView {
  final List<LevelBundle> levels;
  final List<KlineCombineFrame> k1CombineFrames;
  final List<BarCrosshairFeature> barFeatures;
  final List<Buy1Frame> buy1K0;
  final List<Sell1Frame> sell1K0;

  const _SessionView({
    required this.levels,
    required this.k1CombineFrames,
    required this.barFeatures,
    required this.buy1K0,
    required this.sell1K0,
  });
}
