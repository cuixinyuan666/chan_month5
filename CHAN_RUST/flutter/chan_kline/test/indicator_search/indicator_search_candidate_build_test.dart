import 'package:chan_kline/indicator_search/candidate_builder.dart';
import 'package:chan_kline/indicator_search/variable_pool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('optimized(12000) 预留阈值与 K1+ 穿越', () {
    final pool = VariablePool(8);
    final cands = buildCandidates(
      pool,
      const CandidateBuildOptions.optimized(maxCandidates: 12000),
    );
    expect(cands.length, lessThanOrEqualTo(12000));
    expect(cands.any((c) => c.name.startsWith('阈值｜')), isTrue);
    final k1Cross = cands.where(
      (c) =>
          c.name.startsWith('穿越｜') &&
          RegExp(r'K(?!0)\d+').hasMatch(c.name),
    );
    expect(k1Cross.isNotEmpty, isTrue);
  });

  test('optimized(12000) chartMaxKn=16 遵守候选上限', () {
    final pool = VariablePool(16);
    final cands = buildCandidates(
      pool,
      const CandidateBuildOptions.optimized(maxCandidates: 12000),
    );
    expect(cands.length, lessThanOrEqualTo(12000));
    final s = summarizeCandidates(cands);
    expect(s.crosses, greaterThan(0));
    expect(s.thresholds, greaterThan(0));
    expect(s.events, lessThan(14161));
  });

  test('事件池纳入背驰/分型/中枢确认', () {
    final pool = VariablePool(8);
    final buyIds = pool.buyEvents().map((e) => e.variableId).toSet();
    expect(buyIds.any((id) => id.contains('DIVERGENCE.EXISTS')), isTrue);
    expect(buyIds.any((id) => id.contains('FRACTAL_CONFIRM')), isTrue);
    expect(buyIds.any((id) => id.contains('ZS_CONFIRM')), isTrue);
    final orphan = pool.events.where(
      (d) => !pool.buyEvents().contains(d) && !pool.sellEvents().contains(d),
    );
    expect(orphan, isEmpty);
  });

  test('optimized(0) 无上限时仍补穿越与阈值', () {
    final pool = VariablePool(4);
    final cands = buildCandidates(
      pool,
      const CandidateBuildOptions.optimized(maxCandidates: 0),
    );
    expect(cands.any((c) => c.name.startsWith('穿越｜')), isTrue);
    expect(cands.any((c) => c.name.startsWith('阈值｜')), isTrue);
    expect(cands.any((c) => c.name.startsWith('模板｜')), isTrue);
  });

  test('legacyFull 数值穿越含 K0 与 K1+（原 bucket 顺序）', () {
    final pool = VariablePool(4);
    final legacy = buildCandidates(
      pool,
      const CandidateBuildOptions.legacyFull(),
    );
    final crosses =
        legacy.where((c) => c.name.startsWith('穿越｜')).map((c) => c.name);
    expect(crosses.length, greaterThan(50));
    expect(crosses.any((n) => !RegExp(r'K(?!0)\d+').hasMatch(n)), isTrue);
    expect(crosses.any((n) => RegExp(r'K(?!0)\d+').hasMatch(n)), isTrue);
  });
}
