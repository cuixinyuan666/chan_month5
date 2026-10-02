import '../backtest/chip_peak_store.dart';
import '../backtest/divergence_relation_store.dart';
import '../backtest/zhongshu_object_store.dart';
import '../compute/adjacent_ratio_compute.dart';
import '../compute/divergence_freeze_store.dart';
import '../compute/fractal_judgment_compute.dart';
import '../compute/line_slope_compute.dart';
import '../compute/math_series_freeze_store.dart';
import '../compute/step_rhythm_compute.dart';
import '../compute/zs_signal_compute.dart';
import '../models/bs_verdict_frame.dart';
import '../models/buy1_frame.dart';
import '../models/buy2_frame.dart';
import '../models/buy_n_frame.dart';
import '../models/sell1_frame.dart';
import '../models/sell2_frame.dart';
import '../models/sell_n_frame.dart';

/// 步进会话冻结仓（与主图 `_rebuildCombine` 合并链同源）。
class StepFreezeSessionState {
  Map<int, List<FractalJudgmentEvent>> judgmentHistoryByKn = {};
  Map<int, List<ZsSignalEvent>> zsJudgmentHistoryByKn = {};
  Map<int, List<ZsSignalEvent>> zsConfirmHistoryByKn = {};
  final ZhongshuObjectStore zsObjectStore = ZhongshuObjectStore();
  final DivergenceRelationStore diverRelationStore = DivergenceRelationStore();

  Map<int, List<Buy1Frame>> buy1HistoryByKn = {};
  Map<int, List<Sell1Frame>> sell1HistoryByKn = {};
  Map<int, List<Buy2Frame>> buy2HistoryByKn = {};
  Map<int, List<Sell2Frame>> sell2HistoryByKn = {};
  Map<int, List<BuyNFrame>> buyNHistoryByKn = {};
  Map<int, List<SellNFrame>> sellNHistoryByKn = {};
  Map<int, List<BsVerdictFrame>> bsVerdictHistoryByKn = {};

  Map<int, List<AdjacentRatioPoint>> adjacentRatioHistoryByKn = {};
  Map<int, List<LineSlopePoint>> lineSlopeHistoryByKn = {};
  Map<int, List<StepRhythmLinePoint>> stepRhythmHistoryByKn = {};
  final Map<int, StepRhythmState> stepRhythmStateByKn = {};

  final MathSeriesFreezeStore mathFreezeStore = MathSeriesFreezeStore();
  final DivergenceFreezeStore diverFreezeStore = DivergenceFreezeStore();
  final ChipPeakFreezeStore chipPeakStore = ChipPeakFreezeStore();

  void clear() {
    judgmentHistoryByKn.clear();
    zsJudgmentHistoryByKn.clear();
    zsConfirmHistoryByKn.clear();
    zsObjectStore.clear();
    diverRelationStore.clear();
    buy1HistoryByKn.clear();
    sell1HistoryByKn.clear();
    buy2HistoryByKn.clear();
    sell2HistoryByKn.clear();
    buyNHistoryByKn.clear();
    sellNHistoryByKn.clear();
    bsVerdictHistoryByKn.clear();
    adjacentRatioHistoryByKn.clear();
    lineSlopeHistoryByKn.clear();
    stepRhythmHistoryByKn.clear();
    for (final s in stepRhythmStateByKn.values) {
      s.reset();
    }
    stepRhythmStateByKn.clear();
    mathFreezeStore.clear();
    diverFreezeStore.clear();
    chipPeakStore.clear();
  }
}
