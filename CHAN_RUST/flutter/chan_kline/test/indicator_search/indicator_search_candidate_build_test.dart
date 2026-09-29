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
      (c) => c.name.startsWith('穿越｜') && RegExp(r'K[1-9]').hasMatch(c.name),
    );
    expect(k1Cross.isNotEmpty, isTrue);
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
    expect(crosses.any((n) => !RegExp(r'K[1-9]').hasMatch(n)), isTrue);
    expect(crosses.any((n) => RegExp(r'K[1-9]').hasMatch(n)), isTrue);
  });
}
