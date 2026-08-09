import '../models/bar_feature_lookup.dart';
import '../models/buy1_frame.dart';
import '../models/kline_bar.dart';
import '../models/sell1_frame.dart';
import 'ml_bsp_sample.dart';
import 'ml_feature_flat.dart';

/// ML 跳末过程中采集 K0 一类 BS 事件特征（只读 lookup）。
class MlBspSampler {
  final List<MlBspSample> samples = [];
  final Set<String> _seen = {};

  void reset() {
    samples.clear();
    _seen.clear();
  }

  /// 在 `_mergeBsHistory` 之后调用：只采本步新 discovery（x==stepIdx）的 K0 一类。
  void onStep({
    required int stepIdx,
    required List<KlineBar> visibleBars,
    required List<Buy1Frame> buy1K0,
    required List<Sell1Frame> sell1K0,
    required BarFeatureLookup Function() buildLookup,
  }) {
    if (visibleBars.isEmpty) return;
    final barByIdx = {for (final b in visibleBars) b.idx: b};
    final asOfIdx = visibleBars.last.idx;

    final pending = <({String side, int x, String label, double price, int segIdx})>[];
    for (final b in buy1K0) {
      if (b.x != stepIdx) continue;
      final key = 'B|${b.x}|${b.label}|${b.segIdx}';
      if (_seen.contains(key)) continue;
      pending.add((
        side: 'B',
        x: b.x,
        label: b.label,
        price: b.price,
        segIdx: b.segIdx,
      ));
    }
    for (final s in sell1K0) {
      if (s.x != stepIdx) continue;
      final key = 'S|${s.x}|${s.label}|${s.segIdx}';
      if (_seen.contains(key)) continue;
      pending.add((
        side: 'S',
        x: s.x,
        label: s.label,
        price: s.price,
        segIdx: s.segIdx,
      ));
    }
    if (pending.isEmpty) return;

    final lookup = buildLookup();
    final row = lookup.byIdx[asOfIdx];
    final features = row == null
        ? <String, double>{}
        : MlFeatureFlat.flattenRow(Map<String, dynamic>.from(row));

    for (final p in pending) {
      final key = '${p.side}|${p.x}|${p.label}|${p.segIdx}';
      _seen.add(key);
      final openTime =
          barByIdx[p.x]?.timeText ?? barByIdx[asOfIdx]?.timeText ?? '';
      samples.add(
        MlBspSample(
          x: p.x,
          side: p.side,
          label: p.label,
          price: p.price,
          segIdx: p.segIdx,
          openTime: openTime,
          featureFrozenAt: stepIdx,
          features: Map<String, double>.from(features),
        ),
      );
    }
  }
}
