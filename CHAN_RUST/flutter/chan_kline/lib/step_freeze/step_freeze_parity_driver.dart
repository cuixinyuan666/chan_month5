import '../bridge/chan_bridge.dart';
import '../models/chip_config.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_bundle.dart';
import '../models/math_indicator_config.dart';
import 'step_freeze_merger.dart';
import 'step_freeze_session_state.dart';
import 'step_freeze_signatures.dart';

class StepFreezeParityResult {
  StepFreezeParityResult({
    required this.ok,
    required this.mismatches,
    required this.midSnapSegN,
    required this.lastSegN,
    required this.lastK1n,
  });

  final bool ok;
  final List<String> mismatches;
  final int midSnapSegN;
  final int lastSegN;
  final int lastK1n;
}

/// 连续单步 vs 走完瘦包（冻结仓签名与主图合并链同源）。
class StepFreezeParityDriver {
  StepFreezeParityDriver({
    this.truncationCheck = true,
    this.mathConfig = const MathIndicatorConfig(),
    this.chipConfig = const ChipConfig(),
    this.preferDelta = true,
  });

  final bool truncationCheck;
  final MathIndicatorConfig mathConfig;
  final ChipConfig chipConfig;
  final bool preferDelta;

  /// 仅连续单步路径，返回末态冻结仓与末包（探针 T2 需 levels/features）。
  StepFreezeAccumulateResult accumulateStepOnly(List<KlineBar> bars) {
    final out = _drive(bars, slimMiddle: false);
    return StepFreezeAccumulateResult(
      state: out.state,
      lastBundle: out.lastBundle,
      bars: List<KlineBar>.from(bars),
    );
  }

  /// 只连续单步路径，**额外留下每一步喂进去几根 K 的轨迹**。
  ///
  /// 用途：让机器人验证能证明「真的是一根一根走到末根」，而不是一次性喂满再补算 ——
  /// 轨迹若每次只 +1、长度又等于 K0 总根数，就排除了「先喂满再算」的可能。
  /// **不改变任何计算语义**，只是把循环里已有的两个计数记下来。
  StepFreezeWalkTrace walkWithTrace(List<KlineBar> bars) {
    final fed = <int>[];
    final featLen = <int>[];
    final out = _drive(bars, slimMiddle: false, onStepTrace: (n, f) {
      fed.add(n);
      featLen.add(f);
    });
    return StepFreezeWalkTrace(
      fedCounts: fed,
      barFeatureCounts: featLen,
      totalBars: bars.length,
      lastBundle: out.lastBundle,
      state: out.state,
    );
  }

  StepFreezeParityResult run(List<KlineBar> bars) {
    final step = _drive(bars, slimMiddle: false);
    final run = _drive(bars, slimMiddle: true);
    final mismatches = StepFreezeSignatures.diff(step.state, run.state);
    if (step.lastSegN != run.lastSegN) mismatches.add('lastSegN');
    if (step.lastK1n != run.lastK1n) mismatches.add('lastK1n');
    if (step.midSnapSegN != run.midSnapSegN) mismatches.add('midSnapSegN');
    return StepFreezeParityResult(
      ok: mismatches.isEmpty,
      mismatches: mismatches,
      midSnapSegN: step.midSnapSegN,
      lastSegN: step.lastSegN,
      lastK1n: step.lastK1n,
    );
  }

  _RunOut _drive(
    List<KlineBar> bars, {
    required bool slimMiddle,
    void Function(int fed, int barFeatures)? onStepTrace,
  }) {
    final sess = ChanPipelineSession.create(
      preferDelta: preferDelta,
      truncationCheck: truncationCheck,
    );
    final state = StepFreezeSessionState();
    final growing = <KlineBar>[];
    final mid = bars.length < 2 ? 0 : bars.length ~/ 2;
    sess.slimDeltaStructure = slimMiddle;
    KlineCombineBundle last = KlineCombineBundle.empty();
    for (var i = 0; i < bars.length; i++) {
      growing.add(bars[i]);
      if (slimMiddle && i == bars.length - 1) {
        sess.slimDeltaStructure = false;
      }
      last = sess.syncTo(growing);
      StepFreezeMerger.mergeRebuildCombineFreeze(
        state: state,
        bundle: last,
        bars: growing,
        stepIdx: i,
        k0Lines: last.k0Lines,
        truncationCheck: truncationCheck,
        mathConfig: mathConfig,
        chipConfig: chipConfig,
        copyForPaint: false,
        ingestChip: true,
      );
      onStepTrace?.call(growing.length, last.barFeatures.length);
    }
    final midSnap = sess.cache.snapshotAt(bars[mid].idx);
    final midSeg = midSnap == null ? -1 : _segN(midSnap);
    sess.slimDeltaStructure = false;
    sess.dispose();
    return _RunOut(
      state,
      midSeg,
      _segN(last),
      last.k1CombineFrames.length,
      last,
      List<KlineBar>.from(growing),
    );
  }

  int _segN(KlineCombineBundle b) =>
      b.levels.fold<int>(0, (n, lv) => n + lv.segments.length);
}

class StepFreezeAccumulateResult {
  StepFreezeAccumulateResult({
    required this.state,
    required this.lastBundle,
    required this.bars,
  });
  final StepFreezeSessionState state;
  final KlineCombineBundle lastBundle;
  final List<KlineBar> bars;
}

/// 连续单步轨迹：每一步喂进去几根 K、该步之后冻结账里已有几根 barFeatures。
class StepFreezeWalkTrace {
  const StepFreezeWalkTrace({
    required this.fedCounts,
    required this.barFeatureCounts,
    required this.totalBars,
    required this.lastBundle,
    required this.state,
  });

  final List<int> fedCounts;

  /// 与 [fedCounts] 等长：每步之后累计的 barFeatures 根数。
  final List<int> barFeatureCounts;

  final int totalBars;
  final KlineCombineBundle lastBundle;
  final StepFreezeSessionState state;

  /// 步数（每根 K 走一步）。
  int get steps => fedCounts.length;

  /// 轨迹是否「每步只 +1」——排除「一次性喂满再算」的关键证据。
  bool get isOneByOne {
    if (fedCounts.isEmpty) return false;
    if (fedCounts.first != 1) return false;
    for (var i = 1; i < fedCounts.length; i++) {
      if (fedCounts[i] != fedCounts[i - 1] + 1) return false;
    }
    return fedCounts.last == totalBars;
  }

  /// barFeatures 是否同步一步一根地长（逐 K 冻结的又一佐证）。
  bool get featuresGrowOneByOne {
    if (barFeatureCounts.length != fedCounts.length) return false;
    for (var i = 0; i < barFeatureCounts.length; i++) {
      if (barFeatureCounts[i] != fedCounts[i]) return false;
    }
    return true;
  }
}

class _RunOut {
  _RunOut(
    this.state,
    this.midSnapSegN,
    this.lastSegN,
    this.lastK1n,
    this.lastBundle,
    this.bars,
  );
  final StepFreezeSessionState state;
  final int midSnapSegN;
  final int lastSegN;
  final int lastK1n;
  final KlineCombineBundle lastBundle;
  final List<KlineBar> bars;
}
