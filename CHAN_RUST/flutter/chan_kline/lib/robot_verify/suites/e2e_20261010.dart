import 'package:chan_kline/backtest/catalog_lookup.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/kn_volume_series_compute.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/math_indicator_config.dart';
import 'package:chan_kline/compute/kn_clock_timeline.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:chan_kline/step_freeze/step_freeze_parity_driver.dart';
import 'package:chan_kline/step_freeze/step_freeze_session_state.dart';
import 'package:chan_kline/widgets/indicator_legend.dart';

import '../continuous_step_verify.dart';
import '../robot_verify_data.dart';
import '../robot_verify_flutter_test.dart';
import '../robot_verify_model.dart';
import '../robot_verify_suite_meta.dart';

const String kE2e20261010SuiteId = 'e2e_20261010';

/// 本轮（2026-10-09 ~ 10-10）改动的端到端验收套件。
///
/// 覆盖三件必须"真跑一遍"才算数的事：
///  1. **S3 当下性** —— K1+/K2+ 量与笔的区间划分必须用 **asOf 当时**的段，
///     不能借全量最终态的段（那会把当时的累计值整段改写）。
///     断言方式：走**回测出信号的那条链**（`readEvalClockSeries`），与
///     「只喂 `bars[0..asOf]` 重算」的前缀重放逐值对拍。
///  2. **该层无段时刻不得提前报值** —— asOf 很小、K2 一段都没确认时，
///     正确答案是 0 / 无值，旧口径却已报出上千。这是泄漏形态本身。
///  3. **线型签名** —— 布林 / 唐奇安 / 回归通道三类线型签名互不相同，
///     且图例与画布引用同一份 `LegendDash`。
///
/// 另有 `flutter test` 阶段跑本轮改动的对应单测，以及自动挂载的连续单步冻结对拍。

/// 读取一条回测求值序列（真实出信号走的就是它）。
///
/// `SUB.K{n}.VOLUME / TICK_COUNT` 在 `readEvalClockSeries` 里走
/// `_extendedPlotSeries` → `_plotEvalSeries`，这条链**只用到**
/// `bars` / `levels` / `knClock`（外加目录里登记的 evalClock），
/// 其余冻结仓参数根本走不到，因此这里刻意不传 —— 少传一个用不上的
/// 参数，就少一处「类型对不上」的编译期噪音。
///
/// 踩过的坑：曾把 `walkWithTrace` 的返回值当数据容器传，
/// 报 `NoSuchMethodError: StepFreezeWalkTrace has no instance getter 'mathFreeze'`。
List<double> _evalSeries({
  required String variableId,
  required int asOf,
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  KnClockTimeline? clock,
}) =>
    [
      for (final p in readEvalClockSeries(
        variableId: variableId,
        asOf: asOf,
        bars: bars,
        levels: levels,
        knClock: clock,
      ))
        p.value,
    ];

bool _same(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if ((a[i] - b[i]).abs() > 1e-6) return false;
  }
  return true;
}

/// 阶段：S3 —— K1+ 量/笔的当下性（进程内，主图同源的连续单步管道）。
Future<RobotVerifyPhase> runE2eS3PresencePhase({String? klineRoot}) async {
  const phaseId = 'inprocess_s3_presence';

  try {
    ChanBridge.instance.ensureInitialized();
  } catch (e) {
    return RobotVerifyPhase(
      id: phaseId,
      ok: false,
      details: {'error': 'ffi_init_failed', 'message': '$e'},
    );
  }
  final bridge = ChanBridge.instance;
  if (bridge.loadedFfiAbiVersion != kChanFfiAbiVersion) {
    return RobotVerifyPhase(
      id: phaseId,
      ok: false,
      details: {
        'error': 'ffi_abi_mismatch',
        'loaded': bridge.loadedFfiAbiVersion,
        'expected': kChanFfiAbiVersion,
      },
    );
  }

  final plan = await resolveRobotVerify002003LoadPlan(klineRoot: klineRoot);
  if (plan == null) {
    return RobotVerifyPhase(
      id: phaseId,
      ok: true,
      skipped: true,
      skipReason: 'no_verify_data',
      details: {'attempts': lastRobotVerifyDataResolveAttempts()},
    );
  }

  final bars = loadRobotVerifyBars(plan: plan, period: '1m');
  if (bars.length < 60) {
    return RobotVerifyPhase(
      id: phaseId,
      ok: false,
      details: {'error': 'insufficient_bars', 'bars': bars.length},
    );
  }

  // 与主图同源的逐根管道：走一遍即得到「当时段划分」的权威时间线
  final trace = StepFreezeParityDriver(truncationCheck: true).walkWithTrace(bars);
  final bundle = trace.lastBundle;
  final state = trace.state;
  final clock = state.knClockTimeline;

  final checks = <RobotVerifyCheck>[];
  void add(String id, bool ok, [Map<String, Object?> data = const {}]) =>
      checks.add(RobotVerifyCheck(id: id, ok: ok, data: data));

  // 管道本身必须是逐根（否则下面的"当时"没意义）
  add('walk_one_bar_per_step', trace.isOneByOne);
  add('walk_reached_last_bar',
      trace.fedCounts.isNotEmpty && trace.fedCounts.last == bars.length);

  // --- ① 该层无段时刻不得提前报值 ---
  // asOf=6 时 level1 一段都没确认，K2 当时应为 0；旧最终态口径却已报出上千。
  const earlyAsOf = 6;
  const lv = 1; // displayKn = lv + 1 = K2
  final stEarly = clock.at(lv, earlyAsOf);
  final noUnitsYet = stEarly.unitBars.isEmpty && stEarly.activeUnit == null;
  final earlySeries = computeAllKnVolumeSeries(
    bars: bars,
    levels: bundle.levels,
    unitsAsOf: {lv: stEarly},
    asOf: earlyAsOf,
  )[lv + 1];
  final earlyFinal = computeAllKnVolumeSeries(bars: bars, levels: bundle.levels)[lv + 1];
  add('s3_probe_precondition_no_units', noUnitsYet,
      {'unitBars': stEarly.unitBars.length, 'active': stEarly.activeUnit != null});
  if (noUnitsYet && earlySeries != null && earlyFinal != null) {
    add('s3_no_early_value', earlySeries[earlyAsOf] == 0.0,
        {'asOfValue': earlySeries[earlyAsOf]});
    add('s3_leak_was_real', earlyFinal[earlyAsOf] > 0.0,
        {'reason': '旧最终态口径此处仍报出数值，若为 0 则该行情不再复现泄漏，需换探针'});
  }

  // --- ② 新口径 vs 前缀重放（逐 asOf 对拍，走真实求值链）---
  // 注意：前缀侧**必须也带它自己的时钟**，否则比的是采样密度而非因果性。
  const probes = <int>[137, 400, 900];
  var probed = 0;
  final mismatches = <String>[];
  final oldMismatches = <String>[];
  for (final asOf in probes) {
    if (asOf >= bars.length) continue;
    final prefix = bars.sublist(0, asOf + 1);
    final rt =
        StepFreezeParityDriver(truncationCheck: true).walkWithTrace(prefix);

    for (final vid in const [
      'SUB.K1.VOLUME',
      'SUB.K2.VOLUME',
      'SUB.K1.TICK_COUNT',
      'SUB.K2.TICK_COUNT',
    ]) {
      final replay = _evalSeries(
        variableId: vid,
        asOf: asOf,
        bars: prefix,
        levels: rt.lastBundle.levels,
        clock: rt.state.knClockTimeline,
      );
      final now = _evalSeries(
        variableId: vid,
        asOf: asOf,
        bars: bars,
        levels: bundle.levels,
        clock: clock,
      );
      final old = _evalSeries(
        variableId: vid,
        asOf: asOf,
        bars: bars,
        levels: bundle.levels,
        clock: null,
      );
      if (replay.isEmpty && now.isEmpty) continue;
      probed++;
      if (!_same(now, replay)) {
        mismatches.add('$vid@$asOf len=${now.length}/${replay.length}');
      }
      if (!_same(old, replay)) oldMismatches.add('$vid@$asOf');
    }
  }
  add('s3_prefix_probe_count', probed >= 4, {'probed': probed});
  add('s3_matches_prefix_replay', mismatches.isEmpty, {'mismatch': mismatches});
  add('s3_old_path_was_wrong', oldMismatches.isNotEmpty,
      {'oldMismatch': oldMismatches});

  final ok = checks.every((c) => c.ok);
  return RobotVerifyPhase(
    id: phaseId,
    ok: ok,
    details: {
      'bars': bars.length,
      'harness': 'StepFreezeParityDriver.walkWithTrace (与主图同源)',
      'walk': {'steps': trace.steps, 'oneByOne': trace.isOneByOne},
      'probes': probes,
      'prefixReplayProbed': probed,
      'checks': checks.map((c) => c.toJson()).toList(),
    },
  );
}

/// 阶段：线型签名（布林 / 唐奇安 / 回归三类互不相同，且图例画布同源）。
Future<RobotVerifyPhase> runE2eLegendSignaturePhase() async {
  const phaseId = 'inprocess_legend_signature';
  final checks = <RobotVerifyCheck>[];
  void add(String id, bool ok, [Map<String, Object?> data = const {}]) =>
      checks.add(RobotVerifyCheck(id: id, ok: ok, data: data));

  const config = MathIndicatorConfig();
  IndicatorLegendGroup one(MainChartIndicator ind) =>
      buildIndicatorLegends(mains: {ind}, subs: const {}, mathConfig: config)
          .first;

  final boll = one(MainChartIndicator.boll(0));
  final don = one(MainChartIndicator.donchian(0));
  final reg = one(MainChartIndicator.regressionChannel(0));

  String sig(IndicatorLegendGroup g) => g.lines
      .map((l) => '${l.label}:${l.dashPattern?.join(",") ?? "solid"}')
      .join('|');

  // 用**数值**比节距，不要比 join 出来的字符串 ——
  // List<double>.join(",") 产出的是 "4.0,3.0" 而非 "4,3"，
  // 踩过：写死字符串期望值会误判成 FAIL，而实际线型完全正确。
  bool dashIs(LegendLine l, List<double>? want) {
    if (want == null) return l.dashPattern == null;
    if (l.dashPattern == null || l.dashPattern!.length != want.length) {
      return false;
    }
    for (var i = 0; i < want.length; i++) {
      if ((l.dashPattern![i] - want[i]).abs() > 1e-9) return false;
    }
    return true;
  }

  // 布林：中实 / 上实 / 下虚[4,3]
  add('boll_signature',
      dashIs(boll.lines[0], null) &&
          dashIs(boll.lines[1], null) &&
          dashIs(boll.lines[2], const [4, 3]),
      {'sig': sig(boll)});
  // 唐奇安：中长虚[7,4] / 上点虚[2,3] / 下实
  add('donchian_signature',
      dashIs(don.lines[0], const [7, 4]) &&
          dashIs(don.lines[1], const [2, 3]) &&
          dashIs(don.lines[2], null),
      {'sig': sig(don)});
  add('boll_vs_donchian_distinct', sig(boll) != sig(don));
  add('regression_distinct', sig(reg) != sig(boll) && sig(reg) != sig(don),
      {'sig': sig(reg)});
  // 同层同色是全工程约定（不动层色），所以必须靠线型区分 —— 这里钉住这一点
  add('same_layer_same_color',
      boll.lines[0].color == don.lines[0].color,
      {'reason': '布林与唐奇安同层共用层色，靠线型区分；颜色不同反而说明层色体系被破坏'});
  add('upper_lower_dash_differs',
      boll.lines[1].dashPattern != boll.lines[2].dashPattern &&
          don.lines[1].dashPattern != don.lines[2].dashPattern);

  final ok = checks.every((c) => c.ok);
  return RobotVerifyPhase(
    id: phaseId,
    ok: ok,
    details: {'checks': checks.map((c) => c.toJson()).toList()},
  );
}

/// 阶段：本轮改动对应单测（采样钟因果 + 图例）。
Future<RobotVerifyPhase> runE2eFlutterTestPhase({required String klineRoot}) {
  return runFlutterTestJsonPhase(
    phaseId: 'flutter_test_e2e',
    workingDirectory: klineRoot,
    testPathArgs: [
      'test/kn_clock_causality_test.dart',
      'test/indicator_legend_test.dart',
    ],
  );
}

/// 套件编排。
Future<List<RobotVerifyPhase>> runE2e20261010Phases({
  required String klineRoot,
  bool runFlutterTest = true,
}) async {
  final phases = <RobotVerifyPhase>[];
  if (runFlutterTest) {
    phases.add(await runE2eFlutterTestPhase(klineRoot: klineRoot));
  }
  phases.add(await runE2eS3PresencePhase(klineRoot: klineRoot));
  phases.add(await runE2eLegendSignaturePhase());

  final meta = metaForSuite(kE2e20261010SuiteId);
  if (meta?.continuousStepFreeze == true) {
    phases.add(await runContinuousStepFreezePhase(klineRoot: klineRoot));
  }
  return phases;
}