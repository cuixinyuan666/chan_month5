import '../compute/math_series_freeze_store.dart';
import '../models/bar_feature_lookup.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import 'catalog_lookup.dart';
import 'chan_event_store.dart';
import 'chart_line_store.dart';
import 'chip_peak_store.dart';
import 'divergence_relation.dart';
import 'divergence_relation_store.dart';
import 'signal_data_catalog.dart';
import 'structure_object.dart';
import 'trade_clock.dart';
import 'trade_value.dart';
import 'zhongshu_object_store.dart';

/// 变量诊断：看钟、availableAt、图上格子值和计算钟样本，不重算指标。
class TradeVarDiagnosis {
  final String variableId;
  final String displayName;
  final String? groupLabel;
  final TradePanel? panel;
  final int? displayKn;
  final TradeClockFamily? clockFamily;
  final TradeEvalClock? evalClock;
  final TradePlotClock? plotClock;
  final String source;
  final String description;
  final String plainLanguage;
  final bool expressionReady;
  final bool freezePresent;
  /// 当前 asOf 这根 K0 格子上能看见的值（plotClock）
  final TradeScalar plotValue;
  final int plotAt;
  /// 计算钟上 asOf 当时最后一根已有样本
  final EvalClockPoint? evalPoint;
  final int evalSampleCount;
  final String note;
  final TradeChanEvent? lastEvent;
  final int eventCount;
  final ZhongshuObject? currentZs;
  final DivergenceRelation? currentDiver;

  const TradeVarDiagnosis({
    required this.variableId,
    required this.displayName,
    required this.groupLabel,
    required this.panel,
    required this.displayKn,
    required this.clockFamily,
    required this.evalClock,
    required this.plotClock,
    required this.source,
    required this.description,
    required this.plainLanguage,
    required this.expressionReady,
    required this.freezePresent,
    required this.plotValue,
    required this.plotAt,
    required this.evalPoint,
    required this.evalSampleCount,
    required this.note,
    this.lastEvent,
    this.eventCount = 0,
    this.currentZs,
    this.currentDiver,
  });

  String get text {
    final buf = StringBuffer();
    if (plainLanguage.isNotEmpty) {
      buf.writeln('白话说明：');
      buf.writeln(plainLanguage);
      buf.writeln();
    }
    buf.writeln('变量：');
    buf.writeln(displayName.isEmpty ? variableId : displayName);
    buf.writeln(variableId);
    buf.writeln();
    buf.writeln('钟：');
    buf.writeln(clockFamily?.name ?? '未登记');
    buf.writeln();
    buf.writeln('计算钟：');
    buf.writeln(_evalClockCn(evalClock, displayKn));
    if (evalPoint != null) {
      buf.writeln();
      buf.writeln('计算样本：');
      final kn = displayKn ?? 0;
      buf.writeln('K$kn sample #${evalPoint!.evalIndex}');
      buf.writeln();
      buf.writeln('availableAt：');
      buf.writeln('K0 #${evalPoint!.availableAt}');
      buf.writeln();
      buf.writeln('计算钟上的值：');
      buf.writeln(_fmt(evalPoint!.value));
    } else {
      buf.writeln();
      buf.writeln('计算样本：');
      buf.writeln('无（不可用或还没有样本）');
    }
    buf.writeln();
    buf.writeln('plotAt：');
    buf.writeln('K0 #$plotAt');
    buf.writeln();
    buf.writeln('图上格子值：');
    buf.writeln(plotValue.isAvailable ? _fmt(plotValue.value!) : '不可用');
    buf.writeln();
    buf.writeln('来源：');
    buf.writeln(source.isEmpty ? '未登记' : source);
    buf.writeln();
    buf.writeln('冻结仓：');
    buf.writeln(freezePresent ? '有' : '没有（不会现场重算）');
    if (lastEvent != null) {
      buf.writeln();
      buf.writeln('事件：');
      buf.writeln(lastEvent!.eventId);
      buf.writeln('discoveryX：K0 #${lastEvent!.discoveryX}');
      buf.writeln('availableAt：K0 #${lastEvent!.availableAt}');
      buf.writeln('label：${lastEvent!.label}');
      buf.writeln('price：${_fmt(lastEvent!.price)}');
      buf.writeln('截至当前首次发现次数：$eventCount');
    }
    if (currentZs != null) {
      buf.writeln();
      buf.writeln('中枢对象：');
      buf.writeln(currentZs!.objectId);
      buf.writeln('确认时间：K0 #${currentZs!.confirmX}');
      buf.writeln('开始时间：K0 #${currentZs!.startX}');
      buf.writeln('结束时间：K0 #${currentZs!.endX}');
      buf.writeln('HIGH：${_fmt(currentZs!.high)}');
      buf.writeln('LOW：${_fmt(currentZs!.low)}');
      buf.writeln('CENTER：${_fmt(currentZs!.center)}');
      buf.writeln('当前 asOf：K0 #${currentZs!.availableAt}');
      buf.writeln('状态：${currentZs!.state.name}');
    }
    if (currentDiver != null) {
      buf.writeln();
      buf.writeln('背驰关系：');
      buf.writeln(currentDiver!.relationId);
      buf.writeln('发现时间：K0 #${currentDiver!.discoveryX}');
      buf.writeln('当时可见：K0 #${currentDiver!.availableAt}');
      buf.writeln('方向：${divergenceDirectionCn(currentDiver!.direction)}');
      buf.writeln('比较对象：${currentDiver!.referenceObjectId}');
      buf.writeln('当前对象：${currentDiver!.sourceObjectId}');
      if (currentDiver!.referenceZs != null) {
        buf.writeln('比较中枢：${currentDiver!.referenceZs}');
      }
      if (currentDiver!.sourceZs != null) {
        buf.writeln('当前中枢：${currentDiver!.sourceZs}');
      }
      if (currentDiver!.referenceSegment != null) {
        buf.writeln('比较段：${currentDiver!.referenceSegment}');
      }
      if (currentDiver!.sourceSegment != null) {
        buf.writeln('当前段：${currentDiver!.sourceSegment}');
      }
      buf.writeln(
        '力度比：${currentDiver!.ratio == null ? "不可用" : _fmt(currentDiver!.ratio!)}',
      );
      buf.writeln('已确认：${currentDiver!.confirmed ? "是" : "否"}');
    }
    if (note.isNotEmpty) {
      buf.writeln();
      buf.writeln(note);
    }
    return buf.toString().trimRight();
  }
}

String _plainLanguageForDef(TradeVariableDef? def) {
  if (def == null) {
    return '这个键还没登记进变量目录，不能拿来写买卖条件。';
  }
  final parts = <String>[
    '「${def.displayName}」就是：${def.description.isNotEmpty ? def.description : def.variableId}',
    if (def.availabilityNote.isNotEmpty) '什么时候有数：${def.availabilityNote}',
    if (def.blockedReason != null && def.blockedReason!.isNotEmpty)
      '为啥还不能直接写条件：${def.blockedReason}',
    if (def.valueType == TradeValueType.event)
      '这是「有没有发生过」的脉冲事件，只能判断有没有，不能和数字比大小。',
    if (def.valueType == TradeValueType.enumeration)
      '这是方向类枚举（向上/向下），只能选方向，不能和数字比大小。',
  ];
  return parts.join('\n');
}

String _evalClockCn(TradeEvalClock? c, int? kn) {
  if (c == TradeEvalClock.k0Bar) return 'K0 一根一根';
  if (c == TradeEvalClock.knSample) return 'K${kn ?? "n"} 虚拟K样本（右端）';
  return '未定';
}

String _fmt(double v) {
  if (v == v.roundToDouble() && v.abs() >= 1) return v.toStringAsFixed(0);
  return v.toStringAsFixed(4);
}

/// 只读目录 + 冻结仓 + 计算钟样本。UI 不在这里算条件真假。
TradeVarDiagnosis diagnoseTradeVariable({
  required String variableId,
  required int asOf,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  MathSeriesFreezeStore? mathFreeze,
  ChanEventStore chanEvents = ChanEventStore.empty,
  ZhongshuObjectStore? zsObjects,
  DivergenceRelationStore? diverRelations,
  ChartLineStore? lineSeries,
  BarFeatureLookup? features,
  ChipPeakFreezeStore? chipPeaks,
  double bucketStep = 0.1,
  int maxKn = 8,
}) {
  final def = lookupTradeVariable(variableId, maxKn: maxKn);
  final parsed = parseTradeVariableId(variableId);
  var freezePresent = false;
  if (mathFreeze != null && parsed != null && parsed.panel != 'RAW') {
    freezePresent = frozenPlotSeries(parsed: parsed, store: mathFreeze) != null;
  } else if (parsed?.panel == 'RAW') {
    freezePresent = true; // 原生成交量/OHLC 不走冻结仓
  }
  final isZsCurrent = parsed != null &&
      parsed.panel == 'STRUCTURE' &&
      parsed.rest.length >= 2 &&
      parsed.rest[0] == 'ZS' &&
      parsed.rest[1] == 'CURRENT';
  final isZsActive = parsed != null &&
      parsed.panel == 'STRUCTURE' &&
      parsed.rest.length >= 2 &&
      parsed.rest[0] == 'ZS' &&
      parsed.rest[1] == 'ACTIVE';
  if (isZsCurrent || isZsActive) {
    freezePresent = zsObjects != null && !zsObjects.isEmpty;
  }
  final isDiver = parsed != null &&
      parsed.panel == 'STRUCTURE' &&
      parsed.rest.isNotEmpty &&
      parsed.rest[0] == 'DIVERGENCE';
  if (isDiver) {
    freezePresent = diverRelations != null && !diverRelations.isEmpty;
  }
  final isChipPeak = parsed != null &&
      parsed.panel == 'SUB' &&
      parsed.rest.length >= 2 &&
      parsed.rest[1] == 'PEAK' &&
      (parsed.rest[0] == 'CHIP' || parsed.rest[0] == 'TICK');
  if (isChipPeak) {
    freezePresent = chipPeaks != null && !chipPeaks.isEmpty;
  }

  if (def != null &&
      def.expressionReady &&
      def.valueType == TradeValueType.event) {
    final events = listTradeChanEvents(
      variableId: variableId,
      asOf: asOf,
      store: chanEvents,
      levels: levels,
      diverRelations: diverRelations,
      mathFreeze: mathFreeze,
      maxKn: maxKn,
    );
    TradeChanEvent? last;
    for (final e in events) {
      if (e.availableAt <= asOf) last = e;
    }
    final hasHist = !chanEvents.isEmpty ||
        events.isNotEmpty ||
        (isDiver && diverRelations != null && !diverRelations.isEmpty);
    DivergenceRelation? lastDiver;
    if (isDiver && last != null && diverRelations != null) {
      lastDiver = diverRelations.resolveCurrent(
        displayKn: def.displayKn ?? parsed?.kn ?? 0,
        asOf: last.availableAt,
      );
    }
    return TradeVarDiagnosis(
      variableId: variableId,
      displayName: def.displayName,
      groupLabel: def.groupLabel,
      panel: def.panel,
      displayKn: def.displayKn,
      clockFamily: def.clockFamily,
      evalClock: def.evalClock,
      plotClock: def.plotClock,
      source: def.source,
      description: def.description,
      plainLanguage: _plainLanguageForDef(def),
      expressionReady: true,
      freezePresent: hasHist,
      plotValue: last == null
          ? const TradeScalar.unavailable()
          : TradeScalar.num(last.price),
      plotAt: asOf,
      evalPoint: last == null
          ? null
          : EvalClockPoint(
              evalIndex: events.indexOf(last),
              availableAt: last.availableAt,
              value: last.price,
            ),
      evalSampleCount: events.length,
      lastEvent: last,
      eventCount: events.length,
      currentDiver: lastDiver,
      note: last == null
          ? '截至当前这根 K0，还没有首次发现。动态段后续 x 不会当成新的交易事件。'
          : '这是稳定身份的首次发现边沿，不是持续状态。',
    );
  }

  if (def == null || !def.expressionReady) {
    return TradeVarDiagnosis(
      variableId: variableId,
      displayName: def?.displayName ?? variableId,
      groupLabel: def?.groupLabel,
      panel: def?.panel,
      displayKn: def?.displayKn,
      clockFamily: def?.clockFamily,
      evalClock: def?.evalClock,
      plotClock: def?.plotClock,
      source: def?.source ?? '',
      description: def?.description ?? '',
      plainLanguage: _plainLanguageForDef(def),
      expressionReady: false,
      freezePresent: freezePresent,
      plotValue: const TradeScalar.unavailable(),
      plotAt: asOf,
      evalPoint: null,
      evalSampleCount: 0,
      note: def?.blockedReason ?? '未登记进公式，不能当条件',
    );
  }

  final plot = lookupTradeNumeric(
    variableId: variableId,
    asOf: asOf,
    bars: bars,
    levels: levels,
    mathFreeze: mathFreeze,
    zsObjects: zsObjects,
    diverRelations: diverRelations,
    lineSeries: lineSeries,
    features: features,
    chipPeaks: chipPeaks,
    bucketStep: bucketStep,
    k0Confirms: chanEvents.k0FractalConfirms,
  );
  final series = readEvalClockSeries(
    variableId: variableId,
    asOf: asOf,
    bars: bars,
    levels: levels,
    mathFreeze: mathFreeze,
    zsObjects: zsObjects,
    diverRelations: diverRelations,
    lineSeries: lineSeries,
    features: features,
    chipPeaks: chipPeaks,
    bucketStep: bucketStep,
    k0Confirms: chanEvents.k0FractalConfirms,
  );
  EvalClockPoint? last;
  for (final p in series) {
    if (p.availableAt <= asOf) last = p;
  }
  if (plot.isAvailable) freezePresent = true;

  var note = def.description.isEmpty ? def.availabilityNote : def.description;
  ZhongshuObject? currentZs;
  DivergenceRelation? currentDiver;
  if (isZsCurrent) {
    currentZs = zsObjects?.resolveCurrentConfirmedZs(
      displayKn: parsed!.kn,
      asOf: asOf,
    );
    if (!freezePresent) {
      note = '还没有中枢对象仓（需按步进喂入已确认中枢）。$note';
    } else if (currentZs == null) {
      note = '当前这根 K0 还没有已确认中枢（不可用，不是 0）。$note';
    }
  } else if (isZsActive) {
    currentZs = zsObjects?.resolveCurrentActiveZs(
      displayKn: parsed!.kn,
      asOf: asOf,
    );
    if (currentZs == null) {
      note = '当前这根 K 没有盖住的未确认中枢（不可用，不是 0，不沿用）。$note';
    }
  } else if (isDiver) {
    currentDiver = diverRelations?.resolveCurrent(
      displayKn: parsed!.kn,
      asOf: asOf,
    );
    if (!freezePresent) {
      note = '还没有背驰关系仓（需按步进喂入已确认背驰）。$note';
    } else if (currentDiver == null) {
      note = '当前这根 K0 还没有当时可见的确认背驰关系（不可用，不是 0）。$note';
    }
  } else if (!freezePresent && parsed?.panel != 'RAW') {
    note = '冻结仓没有这份序列，读数不可用，不会现场重算。$note';
  } else if (plot.isUnavailable) {
    note = '当前这根 K0 格子没有值（尚未出数或越界）。$note';
  } else if (last != null && last.availableAt != asOf) {
    note =
        '图上格子是铺平后的持值；条件只在计算钟样本右端（K0 #${last.availableAt}）跳动。$note';
  }

  return TradeVarDiagnosis(
    variableId: variableId,
    displayName: def.displayName,
    groupLabel: def.groupLabel,
    panel: def.panel,
    displayKn: def.displayKn,
    clockFamily: def.clockFamily,
    evalClock: def.evalClock,
    plotClock: def.plotClock,
    source: def.source,
    description: def.description,
    plainLanguage: _plainLanguageForDef(def),
    expressionReady: true,
    freezePresent: freezePresent,
    plotValue: plot,
    plotAt: asOf,
    evalPoint: last,
    evalSampleCount: series.length,
    note: note,
    currentZs: currentZs,
    currentDiver: currentDiver,
  );
}
