import '../compute/divergence_freeze_store.dart';
import '../compute/math_series_freeze_store.dart';
import '../models/bs_verdict_frame.dart';
import '../models/buy1_frame.dart';
import '../models/buy2_frame.dart';
import '../models/buy_n_frame.dart';
import '../models/sell1_frame.dart';
import '../models/sell2_frame.dart';
import '../models/sell_n_frame.dart';
import '../backtest/chip_peak_store.dart';
import '../backtest/divergence_relation_store.dart';
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
        'diver': _diverSig(state.diverFreezeStore),
        'chip': _chipSig(state.chipPeakStore),
        'diverRel': _diverRelSig(state.diverRelationStore),
        // 中枢对象快照（此前不在指纹清单里，靠约定保证不回写；现由对拍盯住）
        'zsObject': state.zsObjectStore.signature(),
        // K1+ 采样钟时间线：逐 bar 穿越判定全靠它
        'knClock': _knClockSig(state),
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

  static String _nullableDoubles(List<double?>? s) {
    if (s == null || s.isEmpty) return '';
    return s.map((v) => v == null ? '_' : v.toStringAsFixed(6)).join(',');
  }

  static String _intSeries(List<int> s) =>
      s.isEmpty ? '' : s.map((v) => v.toString()).join(',');

  static String _mathSig(MathSeriesFreezeStore store) {
    final kns = {
      ...store.macdByKn.keys,
      ...store.bollByKn.keys,
      ...store.rsiByKn.keys,
      ...store.kdjByKn.keys,
      ...store.donchianByKn.keys,
      ...store.meanByKn.keys,
      ...store.channelByKn.keys,
    }.toList()
      ..sort();
    final parts = <String>[];
    for (final kn in kns) {
      final m = store.macdByKn[kn];
      if (m != null) {
        parts.add(
          'macd$kn:dif=${_nullableDoubles(m.dif)};dea=${_nullableDoubles(m.dea)};'
          'macd=${_nullableDoubles(m.macd)}',
        );
      }
      final b = store.bollByKn[kn];
      if (b != null) {
        parts.add(
          'boll$kn:mid=${_nullableDoubles(b.mid)};up=${_nullableDoubles(b.up)};'
          'dn=${_nullableDoubles(b.down)}',
        );
      }
      final r = store.rsiByKn[kn];
      if (r != null) {
        parts.add('rsi$kn:${_nullableDoubles(r)}');
      }
      final k = store.kdjByKn[kn];
      if (k != null) {
        parts.add(
          'kdj$kn:k=${_nullableDoubles(k.k)};d=${_nullableDoubles(k.d)};'
          'j=${_nullableDoubles(k.j)}',
        );
      }
      final d = store.donchianByKn[kn];
      if (d != null) {
        parts.add(
          'don$kn:up=${_nullableDoubles(d.up)};mid=${_nullableDoubles(d.mid)};'
          'dn=${_nullableDoubles(d.down)}',
        );
      }
    }
    return parts.join('|');
  }

  static String _diverSig(DivergenceFreezeStore store) {
    final keys = store.byKn.keys.toList()..sort();
    if (keys.isEmpty) return '';
    return keys.map((kn) {
      final algos = store.byKn[kn]!;
      final algoKeys = algos.keys.toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      final body = algoKeys.map((algo) {
        final s = algos[algo]!;
        return '${algo.name}:diver=${_intSeries(s.diverAt)};'
            'in=${_nullableDoubles(s.inAt)};out=${_nullableDoubles(s.outAt)}';
      }).join(',');
      return '$kn:$body';
    }).join(';');
  }

  static String _chipSig(ChipPeakFreezeStore store) =>
      store.stepFreezeParityDigest();

  static String _diverRelSig(DivergenceRelationStore store) =>
      store.stepFreezeParityDigest();

  /// K1+ 采样钟时间线：每一步当时的段边界 + 当时动态段。
  /// 逐 bar 穿越判定全靠它，变了就会改变信号。
  static String _knClockSig(StepFreezeSessionState state) {
    final t = state.knClockTimeline;
    if (t.isEmpty) return '';
    return '${t.length}@${t.lastAsOf}:${t.signature(null)}';
  }
}
