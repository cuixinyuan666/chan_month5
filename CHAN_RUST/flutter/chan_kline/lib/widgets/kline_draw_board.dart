import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../chart/level_window_layout.dart';
import '../compute/k1_bar_view_compute.dart';
import '../models/bar_feature_lookup.dart';
import '../models/chart_indicator.dart';
import '../models/chip_config.dart';
import '../models/k1_bar_view.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_bundle.dart';
import '../models/tick_dist_config.dart';
import 'package:chan_kline/theme/app_palette.dart';
import 'chart_sync_controller.dart';
import 'kline_viewport.dart';
import 'crosshair_tooltip_bridge.dart';
import 'crosshair_tooltip_panel.dart';
import 'kline_chart.dart';
import 'level_chart_grid.dart';

const Map<String, String> kKlineDrawPeriods = <String, String>{
  '1m': '1\u5206\u949f',
  '5m': '5\u5206\u949f',
  '15m': '15\u5206\u949f',
  '30m': '30\u5206\u949f',
  '60m': '60\u5206\u949f',
  '2h': '2\u5c0f\u65f6',
  '4h': '4\u5c0f\u65f6',
  '1d': '1\u65e5',
  '3d': '3\u65e5',
  '1w': '1\u5468',
  '1mon': '1\u6708',
  '3mon': '3\u6708',
  '6mon': '6\u6708',
  '9mon': '9\u6708',
  '12mon': '12\u6708',
  '1y': '1\u5e74',
  '3y': '3\u5e74',
  '6y': '6\u5e74',
};

class KlineDrawCandle {
  const KlineDrawCandle({
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    this.volume = 1,
  });

  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;
}

class KlineDrawDraft {
  const KlineDrawDraft({
    required this.open,
    required this.high,
    required this.low,
    required this.close,
  });

  final double open;
  final double high;
  final double low;
  final double close;
}

class KlineDrawWindowMode {
  const KlineDrawWindowMode.level(this.level) : period = null;
  const KlineDrawWindowMode.period(this.period) : level = 0;

  final int level;
  final String? period;

  bool get isLevel => period == null;

  String get label => isLevel ? 'K$level' : (kKlineDrawPeriods[period] ?? period!);

  int get displayLevel => isLevel ? level : 0;

  String get chartPeriod => period ?? '1m';
}

class KlineDrawBoardModel {
  const KlineDrawBoardModel({
    required this.candles,
    required this.windowCount,
    required this.windowModes,
    this.selected = -1,
    this.priceStep = 0.01,
    this.start = '2026/07/10 09:30:00',
  });

  final List<KlineDrawCandle> candles;
  final int windowCount;
  final List<KlineDrawWindowMode> windowModes;
  final int selected;
  final double priceStep;
  final String start;

  factory KlineDrawBoardModel.initial({int windowCount = 4}) {
    final count = normalizeLevelWindowCount(windowCount);
    return KlineDrawBoardModel(
      candles: const [],
      windowCount: count,
      windowModes: defaultKlineDrawWindowModes(count),
    );
  }

  bool get hasSelection =>
      candles.isNotEmpty && selected >= 0 && selected < candles.length;

  KlineDrawWindowMode modeAt(int slot) =>
      slot >= 0 && slot < windowModes.length
          ? windowModes[slot]
          : const KlineDrawWindowMode.level(0);

  KlineDrawBoardModel copyWith({
    List<KlineDrawCandle>? candles,
    int? windowCount,
    List<KlineDrawWindowMode>? windowModes,
    int? selected,
  }) =>
      KlineDrawBoardModel(
        candles: candles ?? this.candles,
        windowCount: windowCount ?? this.windowCount,
        windowModes: windowModes ?? this.windowModes,
        selected: selected ?? this.selected,
        priceStep: priceStep,
        start: start,
      );

  KlineDrawBoardModel withWindowCount(int count) {
    final next = normalizeLevelWindowCount(count);
    return copyWith(
      windowCount: next,
      windowModes: resizeKlineDrawWindowModes(windowModes, next),
    );
  }

  KlineDrawBoardModel withWindowMode(int slot, KlineDrawWindowMode mode) {
    if (slot < 0 || slot >= windowModes.length) return this;
    if (slot == 0 && (mode.period != null || mode.level != 0)) return this;
    final next = [...windowModes];
    next[slot] = mode;
    return copyWith(windowModes: next);
  }

  KlineDrawBoardModel addCandle(KlineDrawCandle candle) {
    final next = [...candles, candle];
    return copyWith(candles: next, selected: next.length - 1);
  }

  KlineDrawBoardModel select(int index) {
    if (candles.isEmpty) return this;
    return copyWith(selected: index.clamp(0, candles.length - 1));
  }

  KlineDrawBoardModel clearSelection() => copyWith(selected: -1);

  KlineDrawBoardModel deleteSelected() {
    if (!hasSelection) return this;
    final next = [...candles]..removeAt(selected);
    return copyWith(
      candles: next,
      selected: next.isEmpty ? -1 : math.min(selected, next.length - 1),
    );
  }

  KlineDrawBoardModel addSameAfterSelected() {
    if (!hasSelection) return this;
    final next = [...candles];
    next.insert(selected + 1, candles[selected]);
    return copyWith(candles: next, selected: selected + 1);
  }

  KlineDrawBoardModel removeSelected() => deleteSelected();

  KlineDrawBoardModel moveSelectedExtreme(double price) {
    if (!hasSelection) return this;
    final c = candles[selected];
    final up = c.close >= c.open;
    final next = [...candles];
    next[selected] = KlineDrawCandle(
      open: c.open,
      close: c.close,
      high: up ? math.max(price, math.max(c.open, c.close)) : c.high,
      low: up ? c.low : math.min(price, math.min(c.open, c.close)),
      volume: c.volume,
    );
    return copyWith(candles: next);
  }

  List<KlineBar> toBars() {
    final begin = _parseDrawTime(start);
    final out = <KlineBar>[];
    for (var i = 0; i < candles.length; i++) {
      final t = _advanceTradingMinute(begin, i);
      final c = candles[i];
      out.add(KlineBar(
        idx: i,
        timeMs: t.millisecondsSinceEpoch,
        timeText: _formatDrawTime(t),
        open: _roundPrice(c.open),
        high: _roundPrice(c.high),
        low: _roundPrice(c.low),
        close: _roundPrice(c.close),
        volume: c.volume,
        amount: 0,
      ));
    }
    return out;
  }
}

List<KlineDrawWindowMode> defaultKlineDrawWindowModes(int count) {
  const seeded = <KlineDrawWindowMode>[
    KlineDrawWindowMode.level(0),
    KlineDrawWindowMode.level(1),
    KlineDrawWindowMode.period('5m'),
    KlineDrawWindowMode.period('15m'),
  ];
  return [
    for (var i = 0; i < count; i++)
      i < seeded.length ? seeded[i] : KlineDrawWindowMode.level(i),
  ];
}

List<KlineDrawWindowMode> resizeKlineDrawWindowModes(
  List<KlineDrawWindowMode> current,
  int count,
) {
  final defaults = defaultKlineDrawWindowModes(count);
  return [
    for (var i = 0; i < count; i++)
      i == 0
          ? const KlineDrawWindowMode.level(0)
          : (i < current.length ? current[i] : defaults[i]),
  ];
}

KlineDrawDraft buildKlineDrawDraft(double startPrice, double endPrice) {
  final open = startPrice;
  final close = endPrice;
  return KlineDrawDraft(
    open: open,
    close: close,
    high: math.max(open, close),
    low: math.min(open, close),
  );
}

DateTime _parseDrawTime(String raw) {
  final m = RegExp(
    r'(\d{4})\D(\d{1,2})\D(\d{1,2})(?:\D(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?',
  ).firstMatch(raw.trim());
  if (m == null) return DateTime(2026, 7, 10, 9, 30);
  return DateTime(
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    int.parse(m.group(4) ?? '9'),
    int.parse(m.group(5) ?? '30'),
    int.parse(m.group(6) ?? '0'),
  );
}

DateTime _advanceTradingMinute(DateTime begin, int offset) {
  var t = DateTime(begin.year, begin.month, begin.day, begin.hour, begin.minute);
  var left = offset;
  while (left > 0) {
    t = t.add(const Duration(minutes: 1));
    final minutes = t.hour * 60 + t.minute;
    if (minutes == 11 * 60 + 31) {
      t = DateTime(t.year, t.month, t.day, 13);
    } else if (minutes > 15 * 60) {
      final next = t.add(const Duration(days: 1));
      t = DateTime(next.year, next.month, next.day, 9, 30);
    }
    final now = t.hour * 60 + t.minute;
    if (now >= 9 * 60 + 30 && now <= 11 * 60 + 30 ||
        now >= 13 * 60 && now <= 15 * 60) {
      left--;
    }
  }
  return t;
}

String _formatDrawTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}/${two(t.month)}/${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:00';
}

double _roundPrice(double v) => (v * 100).roundToDouble() / 100;

class KlineDrawBoard extends StatefulWidget {
  const KlineDrawBoard({
    super.key,
    required this.model,
    required this.bundle,
    required this.mainIndicators,
    required this.subIndicators,
    required this.truncationCheck,
    required this.earlyDynamicUnit,
    required this.showBuildingDash,
    required this.chipConfig,
    required this.tickDistConfig,
    required this.onChanged,
    required this.onMainIndicatorsChanged,
    required this.onSubIndicatorsChanged,
  });

  final KlineDrawBoardModel model;
  final KlineCombineBundle bundle;
  final Set<MainChartIndicator> mainIndicators;
  final Set<SubChartIndicator> subIndicators;
  final bool truncationCheck;
  final bool earlyDynamicUnit;
  final bool showBuildingDash;
  final ChipConfig chipConfig;
  final TickDistConfig tickDistConfig;
  final ValueChanged<KlineDrawBoardModel> onChanged;
  final ValueChanged<Set<MainChartIndicator>> onMainIndicatorsChanged;
  final ValueChanged<Set<SubChartIndicator>> onSubIndicatorsChanged;

  @override
  State<KlineDrawBoard> createState() => _KlineDrawBoardState();
}

class _KlineDrawBoardState extends State<KlineDrawBoard> {
  final ChartSyncController _sync = ChartSyncController();
  final CrosshairTooltipBridge _tooltipBridge = CrosshairTooltipBridge();
  final ScrollController _tooltipScroll = ScrollController();
  KlineDrawDraft? _draft;
  double _lastPaneHeight = 600;

  KlineDrawBoardModel get model => widget.model;
  KlineCombineBundle get bundle => widget.bundle;

  @override
  void initState() {
    super.initState();
    _tooltipBridge.scrollController = _tooltipScroll;
  }

  @override
  void dispose() {
    _tooltipScroll.dispose();
    _sync.dispose();
    _tooltipBridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bars = [
      ...model.toBars(),
      if (_draft != null)
        KlineBar(
          idx: model.candles.length,
          timeMs: 0,
          timeText: '',
          open: _roundPrice(_draft!.open),
          high: _roundPrice(_draft!.high),
          low: _roundPrice(_draft!.low),
          close: _roundPrice(_draft!.close),
          volume: 0,
          amount: 0,
        ),
    ];
    final views = buildK1BarViews(bundle.k1Bars);
    return Material(
      color: AppPalette.canvasBg,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return ValueListenableBuilder<bool>(
            valueListenable: _tooltipBridge.shown,
            builder: (context, shown, _) {
              return Row(
                children: [
                  Offstage(
                    offstage: !shown,
                    child: SizedBox(
                      width: _tooltipPanelWidth,
                      child: _tooltipPanel(constraints.maxHeight),
                    ),
                  ),
                  Expanded(
                    child: LevelChartGrid(
                      count: model.windowCount,
                      levels: [
                        for (final mode in model.windowModes) mode.displayLevel,
                      ],
                      maxKn: 99,
                      badgeTextBuilder: (level) => '',
                      paneBuilder: (context, slot, level, primary) => _pane(
                        slot: slot,
                        primary: slot == 0,
                        bars: bars,
                        k1Views: views,
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _tooltipPanel(double height) {
    return ValueListenableBuilder<List<CrosshairTooltipRow>>(
      valueListenable: _tooltipBridge.rows,
      builder: (context, rows, _) => CrosshairTooltipPanel(
        rows: rows,
        scrollController: _tooltipScroll,
        maxWidth: _tooltipPanelWidth,
        maxHeight: height,
      ),
    );
  }

  Widget _pane({
    required int slot,
    required bool primary,
    required List<KlineBar> bars,
    required List<K1BarView> k1Views,
  }) {
    final mode = model.modeAt(slot);
    return Stack(
      fit: StackFit.expand,
      children: [
        KlineChart(
          key: ValueKey<String>(
            'kline-draw-$slot-${mode.displayLevel}-${mode.chartPeriod}',
          ),
          interactive: true,
          ownsKeyboard: primary,
          displayLevel: mode.displayLevel,
          forceSubPane: true,
          bars: bars,
          period: mode.chartPeriod,
          combineFrames: bundle.frames,
          k0ConfirmSignals: bundle.k0Confirms,
          barFeatures: bundle.barFeatures,
          k0Lines: bundle.k0Lines,
          k1BarViews: k1Views,
          k1CombineFrames: bundle.k1CombineFrames,
          k1Analysis: bundle.k1Analysis,
          levels: bundle.levels,
          zsK0Frames: bundle.zsK0Frames,
          buy1K0Frames: bundle.buy1K0Frames,
          sell1K0Frames: bundle.sell1K0Frames,
          buy2K0Frames: bundle.buy2K0Frames,
          sell2K0Frames: bundle.sell2K0Frames,
          buyNK0Frames: bundle.buyNK0Frames,
          sellNK0Frames: bundle.sellNK0Frames,
          defaultK0Policy: bundle.defaultK0Policy,
          stepIdx: bars.isEmpty ? 0 : bars.length - 1,
          stepSerial: model.candles.length,
          mainIndicators: widget.mainIndicators,
          subIndicators: widget.subIndicators,
          truncationCheck: widget.truncationCheck,
          earlyDynamicUnit: widget.earlyDynamicUnit,
          showBuildingDash: widget.showBuildingDash,
          chipConfig: widget.chipConfig,
          tickDistConfig: widget.tickDistConfig,
          sync: _sync,
          tooltipBridge: _tooltipBridge,
          dockTooltipPanel: true,
          onCandleDraw: primary ? _onDraw : null,
          onTickDotTap: primary ? _selectCandle : null,
          onTickDotDrag: primary ? _dragSelectedExtreme : null,
          selectedTickIdx: primary && model.hasSelection ? model.selected : -1,
          onMainIndicatorsChanged: widget.onMainIndicatorsChanged,
          onSubIndicatorsChanged: widget.onSubIndicatorsChanged,
        ),
        if (primary && model.candles.isEmpty && _draft == null)
          const IgnorePointer(
            child: Center(
              child: Text('\u6309\u4f4f\u5de6\u952e\u62d6\u52a8\uff0c\u677e\u624b\u751f\u6210\u4e00\u6839 1 \u5206\u949f K \u7ebf'),
            ),
          ),
        if (!primary)
          Positioned(
            left: 8,
            top: 30,
            child: DropdownButton<String>(
              value: mode.isLevel ? 'K${mode.level}' : mode.period,
              items: [
                for (var level = 1; level <= 9; level++)
                  DropdownMenuItem(value: 'K$level', child: Text('K$level')),
                for (final e in kKlineDrawPeriods.entries)
                  if (e.key != '1m')
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) {
                if (v == null) return;
                final next = v.startsWith('K')
                    ? KlineDrawWindowMode.level(int.parse(v.substring(1)))
                    : KlineDrawWindowMode.period(v);
                widget.onChanged(model.withWindowMode(slot, next));
              },
            ),
          ),
        if (primary && model.hasSelection)
          LayoutBuilder(builder: (context, constraints) {
            _lastPaneHeight = constraints.maxHeight;
            final box = _selectedBox(constraints.biggest);
            if (box == null) return const SizedBox.shrink();
            return Stack(children: [
              Positioned(
                left: box.center.dx - 12,
                top: math.max(30, box.top - 28),
                child: _roundAction(Icons.add, () {
                  widget.onChanged(model.addSameAfterSelected());
                }),
              ),
              Positioned(
                left: box.center.dx - 12,
                top: math.min(constraints.maxHeight - 30, box.bottom + 4),
                child: _roundAction(Icons.remove, () {
                  widget.onChanged(model.removeSelected());
                }),
              ),
            ]);
          }),
      ],
    );
  }

  Rect? _selectedBox(Size size) {
    if (!model.hasSelection || size.width <= 0 || size.height <= 0) return null;
    final bars = model.toBars();
    final vp = _sync.viewportFor(0);
    final mainH = size.height * _sync.mainFraction;
    final plotTop = KlineViewport.padT;
    final plotH = math.max(1.0, mainH - plotTop - KlineViewport.padB);
    final range = vp.priceRangeFor(bars);
    final c = bars[model.selected];
    final x = vp.barCenterX(model.selected, size.width);
    final top = range.yOf(c.high, plotTop, plotH);
    final bottom = range.yOf(c.low, plotTop, plotH);
    return Rect.fromLTRB(x - 8, top, x + 8, bottom);
  }

  void _selectCandle(int index) {
    final next = model.hasSelection && model.selected == index
        ? model.clearSelection()
        : model.select(index);
    widget.onChanged(next);
  }

  void _dragSelectedExtreme(int index, double dx, double dy) {
    if (!model.hasSelection || model.selected != index) {
      widget.onChanged(model.select(index));
      return;
    }
    final vp = _sync.viewportFor(0);
    final range = vp.priceRangeFor(model.toBars());
    final plotH = math.max(1.0, _lastPaneHeight * _sync.mainFraction - 56);
    final price = model.candles[index].high - dy * range.span / plotH;
    widget.onChanged(model.moveSelectedExtreme(price));
  }

  Widget _roundAction(IconData icon, VoidCallback onTap) {
    return Material(
      color: AppPalette.surfaceAlt,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 24,
          height: 24,
          child: Icon(icon, size: 14, color: AppPalette.textPrimary),
        ),
      ),
    );
  }

  void _onDraw(double startPrice, double currentPrice, bool finished) {
    final draft = buildKlineDrawDraft(startPrice, currentPrice);
    if (!finished) {
      setState(() => _draft = draft);
      return;
    }
    setState(() => _draft = null);
    widget.onChanged(model.addCandle(KlineDrawCandle(
      open: draft.open,
      high: draft.high,
      low: draft.low,
      close: draft.close,
    )));
  }

  static const double _tooltipPanelWidth = 360;
}
