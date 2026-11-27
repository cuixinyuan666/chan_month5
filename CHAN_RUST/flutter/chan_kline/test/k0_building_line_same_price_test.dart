import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/chart_view_compute.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:flutter_test/flutter_test.dart';

/// K0 构建中虚线：同价位属于合并框，端点固定在该价位首次出现那根。
///
/// 默认数据（002003 tick，2004/07/19 10:47 ~ 2004/07/20 13:09）：
/// （2026-11-28 按实际数据改：0/1=11.66、2=11.67、3=11.68、4/5/6=11.7、7=11.71）
/// - idx=0/1 同为 11.66：首分型前不画线（第二根生成时不得输出虚线）；
/// - idx=4/5/6 同为 11.7：端点固定在 idx=4（11.7 首次出现根），不随合并框内新 K 拉长；
/// - idx=7 新价 11.71：端点正常跟到 7。
void main() {
  late List<KlineBar> bars;

  setUpAll(() {
    final bridge = ChanBridge.instance;
    bridge.ensureInitialized();
    bars = bridge
        .loadKlinesEx(
          dataRoot: bridge.defaultDataRoot(),
          code: '002003',
          beginDate: '2004/07/19 10:47:00',
          endDate: '2004/07/20 13:09:00',
          period: 'tick',
          tickSource: 'protocol',
        )
        .bars;
    expect(bars.length, greaterThan(10), reason: '默认 tick 数据不足');
  });

  /// 与主图 `_drawBuildingK0Line` 同输入：前缀构建 + asOfK1Bars + 判断线。
  List<DisplayBuildingLine> linesAt(int n) {
    final prefix = bars.sublist(0, n + 1);
    final bundle = ChanBridge.instance.buildKlineCombineBundle(prefix);
    final levels = bundle.levels;
    final virtualUnits = asOfK1Bars(
      bars: prefix,
      levels: levels,
      barFeatures: bundle.barFeatures,
      defaultK0Policy: 'pending',
      asOf: n,
      includeBuilding: true,
    );
    final frozenIdx = <int>{
      for (final s in asOfLevelSegments(levels: levels, level: 0, asOf: n))
        s.idx,
    };
    return computeDisplayBuildingLines(
      bars: prefix,
      asOf: n,
      virtualUnits: virtualUnits,
      frozenIdx: frozenIdx,
    );
  }

  test('同价位首分型前不拉线，端点固定在首次出现根', () {
    // idx=0/1 同价：第一根时是点，第二根生成时仍不输出虚线。
    expect(linesAt(0), isEmpty, reason: '首根同价不应画线');
    expect(linesAt(1), isEmpty, reason: '第二根同价不应输出虚线');

    // idx=3 新价 11.68：起点钉在 K0 idx=0（首框内 11.66 首次出现根），终点 3。
    final at3 = linesAt(3);
    expect(at3.length, 1);
    expect(at3.single.begin.barIdx, 0);
    expect(at3.single.end.barIdx, 3);

    // idx=4 首次出现 11.7；idx=5/6 同价：端点固定 4，不随合并框拉长。
    for (final n in [4, 5, 6]) {
      final l = linesAt(n);
      expect(l.length, 1, reason: 'idx=$n 应仍只有一条构建中虚线');
      expect(l.single.begin.barIdx, 0);
      expect(l.single.end.barIdx, 4, reason: 'idx=$n 同价端点应固定在首次出现根 idx=4');
    }

    // idx=7 新价 11.71：端点正常跟到 7。
    final at7 = linesAt(7);
    expect(at7.length, 1);
    expect(at7.single.begin.barIdx, 0);
    expect(at7.single.end.barIdx, 7);
    expect(at7.single.dir, 1);
  });
}
