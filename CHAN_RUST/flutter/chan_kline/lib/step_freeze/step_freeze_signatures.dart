import '../compute/math_series_freeze_store.dart';
import '../models/bs_verdict_frame.dart';
import '../models/buy1_frame.dart';
import '../models/buy2_frame.dart';
import '../models/buy_n_frame.dart';
import '../models/sell1_frame.dart';
import '../models/sell2_frame.dart';
import '../models/sell_n_frame.dart';
import '../compute/adjacent_ratio_compute.dart';
import '../compute/fractal_judgment_compute.dart';
import '../compute/line_slope_compute.dart';
import '../compute/step_rhythm_compute.dart';
import '../compute/zs_signal_compute.dart';
import 'step_freeze_session_state.dart';

/// 对拍用签名（逐类冻结仓）。
class StepFreezeSignatures {
  static Map<String, String> all(StepFreezeSessionState state) => {
        'judgment': _jSig(state.judgmentHistoryByKn),
        'buy1': _buySig(state.buy1HistoryByKn),
        'sell1': _sellSig(state.sell1HistoryByKn),
        'buy2': _buy2Sig(state.buy2HistoryByKn),
        'sell2': _sell2Sig(state.sell2HistoryByKn),
        'buyN': _buyNSig(state.buyNHistoryByKn),
        'sellN': _sellNSig(state.sellNHistoryByKn),
        'bsVerdict': _verdictSig(state.bsVerdictHistoryByKn),
        'zsConfirm': _zsSig(state.zsConfirmHistoryByKn),
        'zsJudge': _zsSig(state.zsJudgmentHistoryByKn),
        'ratio': _ratioSig(state.adjacentRatioHistoryByKn),
        'slope': _slopeSig(state.lineSlopeHistoryByKn),
        'rhythm': _rhythmSig(state.stepRhythmHistoryByKn),
        'math': _mathSig(state.mathFreezeStore),
        'diver': 'kn:${state.diverFreezeStore.byKn.length}',
        'chip': 'bars:${state.chipPeakStore.ingestedBarCount}',
        'diverRel': 'empty:${state.diverRelationStore.isEmpty}',
      };

  static List<String> diff(StepFreezeSessionState a, StepFreezeSessionState b) {
    final sa = all(a);
    final sb = all(b);
    final out = <String>[];
    for (final k in sa.keys) {
      if (sa[k] != sb[k]) out.add(k);
    }
    return out;
  }

  static String _labelSig<T>(Map<int, List<T>> h, String Function(T p) lab) =>
      h.entries
          .map((e) => '${e.key}:${e.value.map(lab).join(',')}')
          .join(';');

  static String _buySig(Map<int, List<Buy1Frame>> h) =>
      _labelSig(h, (p) => '${p.label}@${p.x}');

  static String _sellSig(Map<int, List<Sell1Frame>> h) =>
      _labelSig(h, (p) => '${p.label}@${p.x}');

  static String _buy2Sig(Map<int, List<Buy2Frame>> h) =>
      _labelSig(h, (p) => '${p.label}@${p.x}');

  static String _sell2Sig(Map<int, List<Sell2Frame>> h) =>
      _labelSig(h, (p) => '${p.label}@${p.x}');

  static String _buyNSig(Map<int, List<BuyNFrame>> h) =>
      _labelSig(h, (p) => '${p.label}@${p.x}');

  static String _sellNSig(Map<int, List<SellNFrame>> h) =>
      _labelSig(h, (p) => '${p.label}@${p.x}');

  static String _verdictSig(Map<int, List<BsVerdictFrame>> h) => h.entries
      .map((e) =>
          '${e.key}:${e.value.map((p) => '${p.label}@${p.createX}|${p.state}').join(',')}')
      .join(';');

  static String _zsSig(Map<int, List<ZsSignalEvent>> h) => h.entries
      .map((e) =>
          '${e.key}:${e.value.map((p) => '${p.x1}@${p.x}/${p.value}').join(',')}')
      .join(';');

  static String _jSig(Map<int, List<FractalJudgmentEvent>> h) => h.entries
      .map((e) =>
          '${e.key}:${e.value.map((p) => '${p.x}|${p.fx}|${p.fractalX1}-${p.fractalX2}').join(',')}')
      .join(';');

  static String _ratioSig(Map<int, List<AdjacentRatioPoint>> h) => h.entries
      .map((e) =>
          '${e.key}:${e.value.map((p) => '${p.x}|${p.ratio.toStringAsFixed(6)}|${p.prevIdx}-${p.curIdx}').join(',')}')
      .join(';');

  static String _slopeSig(Map<int, List<LineSlopePoint>> h) => h.entries
      .map((e) =>
          '${e.key}:${e.value.map((p) => '${p.x}|${p.slope.toStringAsFixed(6)}|${p.childIdx}').join(',')}')
      .join(';');

  static String _rhythmSig(Map<int, List<StepRhythmLinePoint>> h) => h.entries
      .map((e) =>
          '${e.key}:${e.value.map((p) => '${p.x}|${p.key}|${p.value.toStringAsFixed(4)}').join(',')}')
      .join(';');

  static String _mathSig(MathSeriesFreezeStore store) {
    return 'macdKn:${store.macdByKn.keys.join(",")}|'
        'bollKn:${store.bollByKn.keys.join(",")}|'
        'rsiKn:${store.rsiByKn.keys.join(",")}';
  }
}
