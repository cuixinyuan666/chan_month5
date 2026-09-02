import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/adjacent_ratio_compute.dart';
import 'package:chan_kline/compute/class1_bs_compute.dart';
import 'package:chan_kline/compute/class2_bs_compute.dart';
import 'package:chan_kline/compute/class_n_bs_compute.dart';
import 'package:chan_kline/compute/fractal_judgment_compute.dart';
import 'package:chan_kline/compute/line_slope_compute.dart';
import 'package:chan_kline/compute/step_rhythm_compute.dart';
import 'package:chan_kline/compute/zs_signal_compute.dart';
import 'package:chan_kline/models/buy1_frame.dart';
import 'package:chan_kline/models/buy2_frame.dart';
import 'package:chan_kline/models/buy_n_frame.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/kline_combine_bundle.dart';
import 'package:chan_kline/models/sell1_frame.dart';
import 'package:chan_kline/models/sell2_frame.dart';
import 'package:chan_kline/models/sell_n_frame.dart';
import 'package:flutter_test/flutter_test.dart';

/// 后台对拍：连续单步冻结 vs 一次性走完瘦包（冻段仍解析）。
///
/// 本机：先有 `windows/native/chan_ffi.dll` 和仓库 `a_Data/002003`。
/// 在 `CHAN_RUST/flutter/chan_kline` 执行：
/// `flutter test test/run_to_end_vs_step_freeze_test.dart`
/// 发布闸门：仓库根 `powershell -File CHAN_RUST/scripts/run_release_gate.ps1`

List<KlineBar> _load({required String period}) {
  final bridge = ChanBridge.instance;
  return bridge.loadKlines(
    dataRoot: bridge.defaultDataRoot(),
    code: '002003',
    beginDate: '2004/07/19 10:47:00',
    endDate: '2004/07/20 13:09:00',
    period: period,
  );
}

int? _activeSegIdx(KlineCombineBundle bundle, int kn) {
  if (kn <= 0) return null;
  for (final lv in bundle.levels) {
    if (lv.level == kn - 1) return lv.activeUnit?.idx;
  }
  return null;
}

class _Freeze {
  final buy1 = <int, List<Buy1Frame>>{};
  final sell1 = <int, List<Sell1Frame>>{};
  final buy2 = <int, List<Buy2Frame>>{};
  final sell2 = <int, List<Sell2Frame>>{};
  final buyN = <int, List<BuyNFrame>>{};
  final sellN = <int, List<SellNFrame>>{};
  final zsJudge = <int, List<ZsSignalEvent>>{};
  final zsConfirm = <int, List<ZsSignalEvent>>{};
  final judgment = <int, List<FractalJudgmentEvent>>{};
  final ratio = <int, List<AdjacentRatioPoint>>{};
  final slope = <int, List<LineSlopePoint>>{};
  final rhythm = <int, List<StepRhythmLinePoint>>{};
  final rhythmState = <int, StepRhythmState>{};

  void ingest({
    required KlineCombineBundle bundle,
    required List<KlineBar> bars,
    required int step,
  }) {
    final maxKn = chartMaxKn(levels: bundle.levels, k0Lines: bundle.k0Lines);
    final knHi = maxKn < 1 ? 1 : maxKn;
    final maxDisplayKn = maxKn <= 0 ? -1 : maxKn - 1;

    for (var kn = 0; kn < knHi; kn++) {
      final log = judgment.putIfAbsent(kn, () => <FractalJudgmentEvent>[]);
      mergeFractalJudgmentEventLog(
        log,
        collectFractalJudgmentEvents(
          kn: kn,
          bars: bars,
          levels: bundle.levels,
          barFeatures: bundle.barFeatures,
        ),
      );
    }

    for (final e in collectBuy1EventsByKn(bundle).entries) {
      mergeBuy1EventLog(
        buy1.putIfAbsent(e.key, () => <Buy1Frame>[]),
        e.value,
        discoveryX: step,
        activeSegIdx: _activeSegIdx(bundle, e.key),
      );
    }
    for (final e in collectSell1EventsByKn(bundle).entries) {
      mergeSell1EventLog(
        sell1.putIfAbsent(e.key, () => <Sell1Frame>[]),
        e.value,
        discoveryX: step,
        activeSegIdx: _activeSegIdx(bundle, e.key),
      );
    }
    for (final e in collectBuy2EventsByKn(bundle).entries) {
      mergeBuy2EventLog(
        buy2.putIfAbsent(e.key, () => <Buy2Frame>[]),
        e.value,
        discoveryX: step,
        activeSegIdx: _activeSegIdx(bundle, e.key),
      );
    }
    for (final e in collectSell2EventsByKn(bundle).entries) {
      mergeSell2EventLog(
        sell2.putIfAbsent(e.key, () => <Sell2Frame>[]),
        e.value,
        discoveryX: step,
        activeSegIdx: _activeSegIdx(bundle, e.key),
      );
    }
    for (final e in collectBuyNEventsByKn(bundle).entries) {
      mergeBuyNEventLog(
        buyN.putIfAbsent(e.key, () => <BuyNFrame>[]),
        e.value,
        discoveryX: step,
        activeSegIdx: _activeSegIdx(bundle, e.key),
      );
    }
    for (final e in collectSellNEventsByKn(bundle).entries) {
      mergeSellNEventLog(
        sellN.putIfAbsent(e.key, () => <SellNFrame>[]),
        e.value,
        discoveryX: step,
        activeSegIdx: _activeSegIdx(bundle, e.key),
      );
    }

    final zs = collectZsFramesByKn(bundle);
    for (final e in zs.entries) {
      final confirmed = mergeZsConfirmEventLog(
        zsConfirm.putIfAbsent(e.key, () => <ZsSignalEvent>[]),
        e.value,
        kn: e.key,
        discoveryX: step,
      );
      mergeZsJudgmentEventLog(
        zsJudge.putIfAbsent(e.key, () => <ZsSignalEvent>[]),
        e.value,
        kn: e.key,
        discoveryX: step,
        confirmedX1ThisStep: confirmed,
      );
    }

    if (maxDisplayKn >= 0) {
      mergeAdjacentRatioForStep(
        historyByKn: ratio,
        levels: bundle.levels,
        displayX: step,
        maxDisplayKn: maxDisplayKn,
        bars: bars,
        barFeatures: bundle.barFeatures,
      );
      mergeLineSlopeForStep(
        historyByKn: slope,
        levels: bundle.levels,
        displayX: step,
        maxDisplayKn: maxDisplayKn,
        bars: bars,
        barFeatures: bundle.barFeatures,
      );
      mergeStepRhythmForStep(
        historyByKn: rhythm,
        stateByKn: rhythmState,
        levels: bundle.levels,
        displayX: step,
        maxDisplayKn: maxDisplayKn,
        bars: bars,
        barFeatures: bundle.barFeatures,
      );
    }
  }

  int _segN(KlineCombineBundle b) =>
      b.levels.fold<int>(0, (n, lv) => n + lv.segments.length);
  int _k1n(KlineCombineBundle b) => b.k1CombineFrames.length;
}

class _RunOut {
  _RunOut(this.freeze, this.midSnapSegN, this.lastSegN, this.lastK1n);
  final _Freeze freeze;
  final int midSnapSegN;
  final int lastSegN;
  final int lastK1n;
}

_RunOut _drive(List<KlineBar> bars, {required bool slimMiddle}) {
  final sess = ChanPipelineSession.create(preferDelta: true);
  final freeze = _Freeze();
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
    freeze.ingest(bundle: last, bars: growing, step: i);
  }
  final midSnap = sess.cache.snapshotAt(bars[mid].idx);
  final midSeg = midSnap == null ? -1 : freeze._segN(midSnap);
  sess.slimDeltaStructure = false;
  sess.dispose();
  return _RunOut(freeze, midSeg, freeze._segN(last), freeze._k1n(last));
}

String _labelSig<T>(Map<int, List<T>> h, String Function(T p) lab) => h.entries
    .map((e) => '${e.key}:${e.value.map(lab).join(',')}')
    .join(';');

String _buySig(Map<int, List<Buy1Frame>> h) =>
    _labelSig(h, (p) => '${p.label}@${p.x}');

String _sellSig(Map<int, List<Sell1Frame>> h) =>
    _labelSig(h, (p) => '${p.label}@${p.x}');

String _buy2Sig(Map<int, List<Buy2Frame>> h) =>
    _labelSig(h, (p) => '${p.label}@${p.x}');

String _sell2Sig(Map<int, List<Sell2Frame>> h) =>
    _labelSig(h, (p) => '${p.label}@${p.x}');

String _buyNSig(Map<int, List<BuyNFrame>> h) =>
    _labelSig(h, (p) => '${p.label}@${p.x}');

String _sellNSig(Map<int, List<SellNFrame>> h) =>
    _labelSig(h, (p) => '${p.label}@${p.x}');

String _zsSig(Map<int, List<ZsSignalEvent>> h) => h.entries
    .map((e) => '${e.key}:${e.value.map((p) => '${p.x1}@${p.x}/${p.value}').join(',')}')
    .join(';');

String _jSig(Map<int, List<FractalJudgmentEvent>> h) => h.entries
    .map((e) =>
        '${e.key}:${e.value.map((p) => '${p.x}|${p.fx}|${p.fractalX1}-${p.fractalX2}').join(',')}')
    .join(';');

String _ratioSig(Map<int, List<AdjacentRatioPoint>> h) => h.entries
    .map((e) =>
        '${e.key}:${e.value.map((p) => '${p.x}|${p.ratio.toStringAsFixed(6)}|${p.prevIdx}-${p.curIdx}').join(',')}')
    .join(';');

String _slopeSig(Map<int, List<LineSlopePoint>> h) => h.entries
    .map((e) =>
        '${e.key}:${e.value.map((p) => '${p.x}|${p.slope.toStringAsFixed(6)}|${p.childIdx}').join(',')}')
    .join(';');

String _rhythmSig(Map<int, List<StepRhythmLinePoint>> h) => h.entries
    .map((e) =>
        '${e.key}:${e.value.map((p) => '${p.x}|${p.key}|${p.value.toStringAsFixed(4)}').join(',')}')
    .join(';');

void _compare(String period, _RunOut step, _RunOut run) {
  void check(String name, String a, String b) {
    expect(a, b, reason: '$period $name 单步 vs 走完');
  }

  check('buy1', _buySig(step.freeze.buy1), _buySig(run.freeze.buy1));
  check('sell1', _sellSig(step.freeze.sell1), _sellSig(run.freeze.sell1));
  check('buy2', _buy2Sig(step.freeze.buy2), _buy2Sig(run.freeze.buy2));
  check('sell2', _sell2Sig(step.freeze.sell2), _sell2Sig(run.freeze.sell2));
  check('buyN', _buyNSig(step.freeze.buyN), _buyNSig(run.freeze.buyN));
  check('sellN', _sellNSig(step.freeze.sellN), _sellNSig(run.freeze.sellN));
  check('zsConfirm', _zsSig(step.freeze.zsConfirm), _zsSig(run.freeze.zsConfirm));
  check('zsJudge', _zsSig(step.freeze.zsJudge), _zsSig(run.freeze.zsJudge));
  check('judgment', _jSig(step.freeze.judgment), _jSig(run.freeze.judgment));
  check('ratio', _ratioSig(step.freeze.ratio), _ratioSig(run.freeze.ratio));
  check('slope', _slopeSig(step.freeze.slope), _slopeSig(run.freeze.slope));
  check('rhythm', _rhythmSig(step.freeze.rhythm), _rhythmSig(run.freeze.rhythm));
  expect(run.lastSegN, step.lastSegN, reason: '$period 末根冻段数');
  expect(run.lastK1n, step.lastK1n, reason: '$period 末根 K1 合并框数');
  expect(run.midSnapSegN, step.midSnapSegN, reason: '$period 半程当步仓冻段数');
}

void main() {
  setUpAll(() {
    ChanBridge.instance.ensureInitialized();
    expect(
      ChanBridge.instance.loadedFfiAbiVersion,
      kChanFfiAbiVersion,
      reason: '库版本须与界面一致；请覆盖 windows/native/chan_ffi.dll',
    );
    expect(
      ChanBridge.instance.supportsAppendDelta,
      isTrue,
      reason: '须有 chan_pipeline_append_delta',
    );
  });

  test('002003 1m 单步冻结 == 走完瘦解析冻结', () {
    final bars = _load(period: '1m');
    expect(bars.length, greaterThan(40), reason: '检查 a_Data/002003 1m');
    final step = _drive(bars, slimMiddle: false);
    final run = _drive(bars, slimMiddle: true);
    _compare('1m', step, run);
  }, timeout: const Timeout(Duration(minutes: 8)));

  test('002003 分笔 单步冻结 == 走完瘦解析冻结', () {
    final bars = _load(period: 'tick');
    expect(bars.length, greaterThan(80), reason: '检查 a_Data/002003 分笔');
    final step = _drive(bars, slimMiddle: false);
    final run = _drive(bars, slimMiddle: true);
    _compare('tick', step, run);
  }, timeout: const Timeout(Duration(minutes: 12)));
}
