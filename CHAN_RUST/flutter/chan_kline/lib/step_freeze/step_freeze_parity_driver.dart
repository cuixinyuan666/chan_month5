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

  _RunOut _drive(List<KlineBar> bars, {required bool slimMiddle}) {
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
