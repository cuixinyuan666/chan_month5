import '../compute/math_series_freeze_store.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import 'catalog_lookup.dart';
import 'chan_event_store.dart';
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
  });

  String get text {
    final buf = StringBuffer();
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
    if (note.isNotEmpty) {
      buf.writeln();
      buf.writeln(note);
    }
    return buf.toString().trimRight();
  }
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
  if (isZsCurrent) {
    freezePresent = zsObjects != null && !zsObjects.isEmpty;
  }

  if (def != null &&
      def.expressionReady &&
      def.valueType == TradeValueType.event) {
    final events = listTradeChanEvents(
      variableId: variableId,
      asOf: asOf,
      store: chanEvents,
      levels: levels,
      maxKn: maxKn,
    );
    TradeChanEvent? last;
    for (final e in events) {
      if (e.availableAt <= asOf) last = e;
    }
    final hasHist = !chanEvents.isEmpty || events.isNotEmpty;
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
  );
  final series = readEvalClockSeries(
    variableId: variableId,
    asOf: asOf,
    bars: bars,
    levels: levels,
    mathFreeze: mathFreeze,
    zsObjects: zsObjects,
  );
  EvalClockPoint? last;
  for (final p in series) {
    if (p.availableAt <= asOf) last = p;
  }

  var note = def.description.isEmpty ? def.availabilityNote : def.description;
  ZhongshuObject? currentZs;
  if (isZsCurrent) {
    currentZs = zsObjects?.resolveCurrentConfirmedZs(
      displayKn: parsed.kn,
      asOf: asOf,
    );
    if (!freezePresent) {
      note = '还没有中枢对象仓（需按步进喂入已确认中枢）。$note';
    } else if (currentZs == null) {
      note = '当前这根 K0 还没有已确认中枢（不可用，不是 0）。$note';
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
    expressionReady: true,
    freezePresent: freezePresent,
    plotValue: plot,
    plotAt: asOf,
    evalPoint: last,
    evalSampleCount: series.length,
    note: note,
    currentZs: currentZs,
  );
}
