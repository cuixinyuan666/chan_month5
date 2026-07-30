import 'k0_confirm_signal.dart';
import 'bar_crosshair_feature.dart';
import 'buy1_frame.dart';
import 'sell1_frame.dart';
import 'k0_line.dart';
import 'kline_bar.dart';
import 'chart_indicator.dart';
import 'kline_combine_frame.dart';
import 'level_models.dart';
import 'k1_analysis.dart';
import '../compute/fractal_judgment_compute.dart';
import '../compute/class1_bs_compute.dart';
import '../compute/kn_volume_series_compute.dart';

/// 十字线 tooltip 一行：键值 / 层级分隔线 / 同层内容分隔线。
class CrosshairTooltipRow {
  const CrosshairTooltipRow.kv(this.label, this.value)
      : isSeparator = false,
        isStar = false;
  const CrosshairTooltipRow.separator()
      : label = '',
        value = '',
        isSeparator = true,
        isStar = false;
  const CrosshairTooltipRow.starSeparator()
      : label = '',
        value = '',
        isSeparator = false,
        isStar = true;

  final String label;
  final String value;
  final bool isSeparator;
  final bool isStar;

  /// 扁平字符串（测试/历史快照用）
  String get flat {
    if (isSeparator) return '===============================';
    if (isStar) return '-。-。-。-。-。-。-。-。-。-';
    return '$label:$value';
  }

  /// 数字值外接方形框，便于与字符串区分
  static String boxNum(dynamic v) => v == null ? '【—】' : '【$v】';

  /// 复合字符串中所有数字（含小数）外接方形框
  /// 例：O11.89/H11.90 → O【11.89】/H【11.90】
  static final _numRe = RegExp(r'(\d+\.?\d*)');
  static String boxNumInString(String s) =>
      s.replaceAllMapped(_numRe, (m) => '【${m.group(0)}】');
}

/// 逐 K 字典式特征索引（ML / 十字线 tooltip 同源，均用 barFeatures 逐步冻结快照）。
class BarFeatureLookup {
  BarFeatureLookup._({
    required this.byIdx,
    this.totalLevels = 0,
    this.zsAfterK0 = const [],
    this.knZsAfterKn = const {},
  });

  final Map<int, Map<String, dynamic>> byIdx;

  /// 穷尽后的 N 段总层数（tooltip 对未诞生层输出占位行）
  final int totalLevels;

  /// 十字线：K0 块后追加的中枢 ZG/ZD 行
  final List<CrosshairTooltipRow> zsAfterK0;

  /// 十字线：各 Kn 块后追加的中枢 ZG/ZD 行
  final Map<int, List<CrosshairTooltipRow>> knZsAfterKn;

  factory BarFeatureLookup.build({
    required List<KlineBar> bars,
    required List<KlineCombineFrame> combineFrames,
    required List<K0ConfirmSignal> k0Confirms,
    List<BarCrosshairFeature> barFeatures = const [],
    List<K0Line> k0Lines = const [],
    K1AnalysisBundle k1Analysis = const K1AnalysisBundle(),
    List<LevelBundle> levels = const [],
    Map<int, List<Buy1Frame>> buy1HistoryByKn = const {},
    Map<int, List<Sell1Frame>> sell1HistoryByKn = const {},
    List<Buy1Frame> buy1K0Frames = const [],
    List<Sell1Frame> sell1K0Frames = const [],
    Set<SubChartIndicator> subIndicators = const {},
    bool truncationCheck = true,
    /// 分型判断会话事件日志（有则优先；扫全部历史点）
    Map<int, List<FractalJudgmentEvent>> judgmentHistoryByKn = const {},
    /// 当步截断位（idx）：与副图指标 _drawKnFractalJudgmentSubChart 的 maxX=segAsOf 一致，
    /// 十字线激活时传入 widget.segAsOf，使 tooltip 分型判断与副图同源同截断。
    int? asOf,
    List<CrosshairTooltipRow> zsAfterK0 = const [],
    Map<int, List<CrosshairTooltipRow>> knZsAfterKn = const {},
  }) {
    final byIdx = <int, Map<String, dynamic>>{};

    final featureByIdx = {for (final f in barFeatures) f.idx: f};

    // 各层确认查表：level_confirms[n][x] = Kn 合并分型确认（当步冻结；含截断）
    // Kn 块显示 K(n+1) 端点确认（K0 块显示 levels[1]=K1 确认，旧称「K线合并分型确认」）
    final levelConfirmByX = <int, Map<int, LevelConfirm>>{};
    for (final lv in levels) {
      final m = <int, LevelConfirm>{};
      for (final c in lv.confirms) {
        if (c.value == 1 || c.value == -1) m[c.x] = c;
      }
      levelConfirmByX[lv.level] = m;
    }

    for (final b in bars) {
      final feat = featureByIdx[b.idx];
      byIdx[b.idx] = {
        'idx': b.idx,
        'time_ms': b.timeMs,
        'time_text': b.timeText,
        'weekday': feat?.weekday ?? '-',
        'merge_inner_seq': feat?.mergeInnerSeq ?? 0,
        'merge_count': feat?.mergeCount ?? 1,
        'merge_box_seq': feat?.mergeBoxSeq ?? -1,
        'combine_fx': feat?.combineFx ?? 'UNKNOWN',
        'combine_high': feat?.combineHigh ?? b.high,
        'combine_low': feat?.combineLow ?? b.low,
        'k1_idx': feat?.k1Idx,
        'k1_merge_inner_seq': feat?.k1MergeInnerSeq ?? 0,
        'k1_merge_count': feat?.k1MergeCount ?? 1,
        'k1_open': feat?.k1Open ?? 0,
        'k1_high': feat?.k1High ?? 0,
        'k1_low': feat?.k1Low ?? 0,
        'k1_close': feat?.k1Close ?? 0,
        'k1_volume': feat?.k1Volume ?? 0,
        'k1_combine_high': feat?.k1CombineHigh ?? 0,
        'k1_combine_low': feat?.k1CombineLow ?? 0,
        'k1_combine_fx': feat?.k1CombineFx ?? 'UNKNOWN',
        'levels': feat?.levels ?? const <LevelSnap>[],
        'level_confirms': {
          for (final e in levelConfirmByX.entries)
            if (e.value.containsKey(b.idx)) e.key: e.value[b.idx]!,
        },
        'open': b.open,
        'high': b.high,
        'low': b.low,
        'close': b.close,
        'volume': b.volume,
        'amount': b.amount,
        if (b.metrics.isNotEmpty) 'metrics': Map<String, dynamic>.from(b.metrics),
        'sub': <String, dynamic>{},
      };
    }

    // 合并线框仅结构展示；十字线/ML 的 fx、count 取自 barFeatures 逐步口径
    for (final f in combineFrames) {
      for (var x = f.x1; x <= f.x2; x++) {
        final row = byIdx.putIfAbsent(x, () => {'idx': x});
        row['combine'] = {
          'x1': f.x1,
          'x2': f.x2,
          'high': f.high,
          'low': f.low,
          'fx': f.fx,
          'count': f.count,
          'in_merge': f.count > 1,
        };
      }
    }

    for (final sig in k0Confirms) {
      final row = byIdx.putIfAbsent(sig.x, () => {'idx': sig.x});
      row['k0_confirm'] = {
        'x': sig.x,
        'fx': sig.fx,
        'value': sig.value,
        'fractal_x1': sig.fractalX1,
        'fractal_x2': sig.fractalX2,
        'truncated': sig.truncated,
      };
      if (subIndicators.any((e) =>
          e.kind == SubIndicatorKind.fractalConfirm && e.kn == 1)) {
        // kn=1（最低层）回退源：旧 k0_confirm（K0 原始K分型）
        (row['sub'] as Map<String, dynamic>)['k0_confirm_value'] = sig.value;
      }
    }

    for (final sig in k1Analysis.k1Confirms) {
      if (sig.fx != 'TOP' && sig.fx != 'BOTTOM') continue;
      if (sig.value == 0) continue;
      final row = byIdx.putIfAbsent(sig.x, () => {'idx': sig.x});
      row['k1_confirm_signal'] = {
        'x': sig.x,
        'fx': sig.fx,
        'value': sig.value,
        'peak_k1_idx': sig.peakK1Idx,
        'fractal_x1': sig.fractalX1,
        'fractal_x2': sig.fractalX2,
      };
    }

    for (final seg in k0Lines) {
      for (var x = seg.beginConfirmX; x <= seg.endConfirmX; x++) {
        final row = byIdx.putIfAbsent(x, () => {'idx': x});
        row['k0_line'] = {
          'idx': seg.idx,
          'dir': seg.dir,
          'begin_confirm_x': seg.beginConfirmX,
          'end_confirm_x': seg.endConfirmX,
          'prev_idx': seg.prevIdx,
          'next_idx': seg.nextIdx,
        };
      }
    }

    for (final snap in k1Analysis.barSubSnapshots) {
      final row = byIdx.putIfAbsent(snap.idx, () => {'idx': snap.idx});
      row['k1_snapshot'] = {
        'building_seg_dir': snap.buildingSegDir,
        'first_seg_dir': snap.firstSegDir,
        'k1_confirm': snap.k1Confirm,
      };
      // 已删副图「首K1向 / K2确认」：快照字段仍保留供其它用途
    }

    // Kn成交量：K0=原生；Kn=下层增量累加步进（与副图绘制同源）。
    // 写入 sub 供：① tooltip 各层 OHLCV 的 VOL 槽；② 副图读数。
    {
      final allVol = computeAllKnVolumeSeries(
        bars: bars,
        levels: levels,
        barFeatures: barFeatures,
      );
      for (final e in allVol.entries) {
        final series = e.value;
        for (var i = 0; i < bars.length; i++) {
          final row =
              byIdx.putIfAbsent(bars[i].idx, () => {'idx': bars[i].idx});
          final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
              as Map<String, dynamic>;
          sub['volume_${e.key}'] = i < series.length ? series[i] : 0.0;
        }
      }
    }

    // Kn一类BS：只扫会话历史（含动态 active 各 K0 颗粒度点）；禁止 asOf 重算消点。
    // 踩坑：history 若缺本步 x，十字 asOf=当前步会 sellAtAsOf=null（26有点、27空）。
    {
      // 兼容：未传 history 时回退 K0 帧（旧调用）
      final buyHist = Map<int, List<Buy1Frame>>.from(buy1HistoryByKn);
      final sellHist = Map<int, List<Sell1Frame>>.from(sell1HistoryByKn);
      if (buyHist.isEmpty && buy1K0Frames.isNotEmpty) {
        buyHist[0] = buy1K0Frames;
      }
      if (sellHist.isEmpty && sell1K0Frames.isNotEmpty) {
        sellHist[0] = sell1K0Frames;
      }
      // 若仍无 history，回退 levels 内帧（末态；仅兜底）
      if (buyHist.isEmpty && sellHist.isEmpty) {
        for (final lv in levels) {
          if (lv.buy1Frames.isNotEmpty) buyHist[lv.level] = lv.buy1Frames;
          if (lv.sell1Frames.isNotEmpty) sellHist[lv.level] = lv.sell1Frames;
        }
      }

      final barCount = bars.isEmpty ? 0 : bars.last.idx + 1;
      final kns = <int>{...buyHist.keys, ...sellHist.keys};
      for (final kn in kns) {
        final buySeries = expandBuy1LabelsToSeries(
          buyHist[kn] ?? const [],
          barCount,
          maxX: asOf,
        );
        final sellSeries = expandSell1LabelsToSeries(
          sellHist[kn] ?? const [],
          barCount,
          maxX: asOf,
        );
        for (final b in bars) {
          final row = byIdx.putIfAbsent(b.idx, () => {'idx': b.idx});
          final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
              as Map<String, dynamic>;
          if (b.idx >= 0 &&
              b.idx < buySeries.length &&
              buySeries[b.idx] != null) {
            sub['buy1_$kn'] = buySeries[b.idx];
          }
          if (b.idx >= 0 &&
              b.idx < sellSeries.length &&
              sellSeries[b.idx] != null) {
            sub['sell1_$kn'] = sellSeries[b.idx];
          }
        }
      }
    }

    if (subIndicators.any((e) =>
        e.kind == SubIndicatorKind.fractalPeakDist && e.kn == 1)) {
      // kn=1（最低层）回退源：旧 K0连线极点距（barFeatures）
      for (final f in barFeatures) {
        final row = byIdx.putIfAbsent(f.idx, () => {'idx': f.idx});
        (row['sub'] as Map<String, dynamic>)['fractal_peak_dist'] =
            f.fractalPeakDist;
      }
    }

    // Kn>=1 极点距：由该层 confirms 当步起算（与副图折线同口径；level=kn）
    for (final ind in subIndicators) {
      if (ind.kind != SubIndicatorKind.fractalPeakDist || ind.kn < 1) {
        continue;
      }
      LevelBundle? bundle;
      for (final lv in levels) {
        if (lv.level == ind.kn) {
          bundle = lv;
          break;
        }
      }
      if (bundle == null || bars.isEmpty) continue;
      final series = _peakDistSeries(bars.length, bundle.confirms);
      for (var i = 0; i < bars.length; i++) {
        final row = byIdx.putIfAbsent(bars[i].idx, () => {'idx': bars[i].idx});
        (row['sub'] as Map<String, dynamic>)['fractal_peak_dist_${ind.kn}'] =
            series[i];
      }
    }

    // 展示轨分型判断：为每个层级(kn=1..N)计算，供副图指标与十字线 tooltip「Kn分型判断」共用；
    // 与「Kn分型确认」同口径：仅成立后当步有点，不整框回填。
    // tooltip 与副图「indicator Kn分型判断」完全同源：两端都用 judgmentHistoryByKn[kn]
    // 事件列表、都按 segAsOf 截断(maxX: asOf)、都取 per-x 末态(后者覆盖)。
    // 不再用 collectFractalJudgmentEvents 兜底——否则 history 缺失的层 tooltip 显示末态、
    // 副图却无点，造成两端不对应。history 为空则全 UNKNOWN(显示 0)，与副图一致。
    // 写到 levels.length + 1：tooltip「K{N}块分型判断」需读 fractal_judgment_{N+1}
    // （对最高层连线做的分型判断），与副图指标 K{N}分型判断(kn=N+1) 同口径。
    if (bars.isNotEmpty) {
      for (var kn = 1; kn <= levels.length + 1; kn++) {
        final history = judgmentHistoryByKn[kn];
        final fxSeries = history != null && history.isNotEmpty
            ? expandJudgmentEventsToSeries(history, bars.last.idx + 1,
                maxX: asOf)
            : const <String>[];
        final truncSeries = history != null && history.isNotEmpty
            ? expandJudgmentEventsToTruncSeries(history, bars.last.idx + 1,
                maxX: asOf)
            : const <bool>[];
        for (final b in bars) {
          final row = byIdx.putIfAbsent(b.idx, () => {'idx': b.idx});
          final fx = b.idx >= 0 && b.idx < fxSeries.length
              ? fxSeries[b.idx]
              : 'UNKNOWN';
          (row['sub'] as Map<String, dynamic>)['fractal_judgment_$kn'] = fx;
          final trunc = b.idx >= 0 && b.idx < truncSeries.length
              ? truncSeries[b.idx]
              : false;
          (row['sub'] as Map<String, dynamic>)['fractal_judgment_trunc_$kn'] =
              trunc;
        }
      }
    }

    return BarFeatureLookup._(
      byIdx: byIdx,
      totalLevels: levels.length,
      zsAfterK0: zsAfterK0,
      knZsAfterKn: knZsAfterKn,
    );
  }

  Map<String, dynamic>? operator [](int idx) => byIdx[idx];

  Map<String, dynamic>? at(int idx) => byIdx[idx];

  /// 星期中文 → w1..w7（周一=w1 … 周六=w6，周日=w7）。
  static String weekdayToW(String weekday) {
    const map = {
      '周一': 'w1',
      '周二': 'w2',
      '周三': 'w3',
      '周四': 'w4',
      '周五': 'w5',
      '周六': 'w6',
      '周日': 'w7',
    };
    return map[weekday] ?? weekday;
  }

  static String _fmtPrice(double v) => v.toStringAsFixed(2);

  static String _fmtVol(num vol) => vol == vol.roundToDouble()
      ? vol.toInt().toString()
      : vol.toStringAsFixed(2);

  static String _fmtOhlcv({
    required double open,
    required double high,
    required double low,
    required double close,
    required num volume,
  }) {
    return 'O${_fmtPrice(open)}/H${_fmtPrice(high)}/L${_fmtPrice(low)}/C${_fmtPrice(close)}/VOL${_fmtVol(volume)}';
  }

  /// 十字线主 tooltip 结构化行（表格渲染用）。
  List<CrosshairTooltipRow> crosshairTooltipRows(
    int idx, {
    required String timePart,
    Set<SubChartIndicator> subIndicators = const {},
  }) {
    final row = byIdx[idx];
    if (row == null) return const [];

    final weekday = weekdayToW(row['weekday'] as String? ?? '-');
    final mergeInner = row['merge_inner_seq'] ?? 0;
    final mergeBoxSeq = row['merge_box_seq'] ?? 0;

    final open = (row['open'] as num?)?.toDouble() ?? 0;
    final high = (row['high'] as num?)?.toDouble() ?? 0;
    final low = (row['low'] as num?)?.toDouble() ?? 0;
    final close = (row['close'] as num?)?.toDouble() ?? 0;
    // K0 的 VOL 槽：用 K0成交量序列（原生量）替换预留位
    final subMap = row['sub'];
    final volume = (subMap is Map && subMap['volume_0'] is num)
        ? subMap['volume_0'] as num
        : ((row['volume'] as num?) ?? 0);
    final combineHigh = (row['combine_high'] as num?)?.toDouble() ?? high;
    final combineLow = (row['combine_low'] as num?)?.toDouble() ?? low;

    // 原始K分型确认（=k0_confirms=levels[0].confirms；合并原始K顶/底分型，其端点连即 K0连线/K1，并被重铸为 K1Bar 供 K2）。仅 ±1 显示，截断加"(截断)"，未确认为 0，与 Kn 同口径
    var combineFxConfirm = '0';
    final k0Confirm = row['k0_confirm'];
    if (k0Confirm is Map) {
      final v = k0Confirm['value'];
      if (v is num && (v == 1 || v == -1)) {
        combineFxConfirm = k0Confirm['truncated'] == true ? '$v(截断)' : '$v';
      }
    }

    final out = <CrosshairTooltipRow>[
      CrosshairTooltipRow.kv('日期时间', '$timePart     $weekday'),
      const CrosshairTooltipRow.separator(),
      CrosshairTooltipRow.kv('K0[No.]', CrosshairTooltipRow.boxNum(row['idx'])),
      CrosshairTooltipRow.kv(
        'K0',
        CrosshairTooltipRow.boxNumInString(_fmtOhlcv(open: open, high: high, low: low, close: close, volume: volume)),
      ),
      const CrosshairTooltipRow.starSeparator(),
      CrosshairTooltipRow.kv(
        'K0合并',
        CrosshairTooltipRow.boxNumInString('H${_fmtPrice(combineHigh)}/L${_fmtPrice(combineLow)}'),
      ),
      CrosshairTooltipRow.kv('K0合并K0序', CrosshairTooltipRow.boxNum(mergeInner)),
      CrosshairTooltipRow.kv('K0合并组No.', mergeBoxSeq >= 0 ? CrosshairTooltipRow.boxNum(mergeBoxSeq) : '未成框'),
      CrosshairTooltipRow.kv('K0分型确认', CrosshairTooltipRow.boxNum(combineFxConfirm)),
      const CrosshairTooltipRow.starSeparator(),
      ...zsAfterK0,
      ..._levelBlockRows(idx),
    ];

    final subs = crosshairSubRows(
      idx,
      // K0分型确认已在 K0 块；成交量已写入各层 OHLCV 的 VOL 槽——主 tooltip 底部不再重复
      subIndicators
          .where((e) =>
              !(e.kind == SubIndicatorKind.fractalConfirm && e.kn == 1) &&
              e.kind != SubIndicatorKind.volume)
          .toSet(),
    );
    if (subs.isNotEmpty) {
      out.add(const CrosshairTooltipRow.separator());
      out.addAll(subs);
    }
    return out;
  }

  /// 扁平字符串列表（测试/历史快照兼容）。
  List<String> crosshairTooltipLines(int idx, {required String timePart}) {
    return crosshairTooltipRows(idx, timePart: timePart).map((e) => e.flat).toList();
  }

  List<String> crosshairSubLines(int idx, Set<SubChartIndicator> active) {
    return crosshairSubRows(idx, active).map((e) => e.flat).toList();
  }

  List<CrosshairTooltipRow> crosshairSubRows(
    int idx,
    Set<SubChartIndicator> active,
  ) {
    final row = byIdx[idx];
    if (row == null) return const [];
    final sub = row['sub'];
    if (sub is! Map || sub.isEmpty) return const [];

    final lines = <CrosshairTooltipRow>[];
    void add(String label, dynamic v) {
      if (v == null) return;
      lines.add(CrosshairTooltipRow.kv(label, '$v'));
    }

    for (final ind in active) {
      if (ind.kind == SubIndicatorKind.volume) {
        final key = 'volume_${ind.kn}';
        if (sub.containsKey(key)) {
          add(ind.label, sub[key]);
        } else if (ind.kn <= 0) {
          // 回退：旧 volume 字段
          add(ind.label, sub['volume'] ?? row['volume']);
        }
      }
      if (ind.kind == SubIndicatorKind.fractalConfirm) {
        dynamic v;
        var truncated = false;
        if (ind.kn == 1) {
          // K0分型确认：与 tooltip K0 块同源（勿用 level_confirms[1]）
          v = sub['k0_confirm_value'];
          final bc = row['k0_confirm'];
          if (bc is Map) truncated = bc['truncated'] == true;
        } else {
          final confirms = row['level_confirms'];
          if (confirms is Map && confirms.containsKey(ind.kn)) {
            final c = confirms[ind.kn];
            if (c is LevelConfirm) {
              v = c.value;
              truncated = c.truncated;
            } else if (c is Map) {
              v = c['value'];
              truncated = c['truncated'] == true;
            }
          }
        }
        add(ind.label, v == null ? '0' : (truncated ? '$v(截断)' : '$v'));
      }
      if (ind.kind == SubIndicatorKind.fractalJudgment) {
        final fx = sub['fractal_judgment_${ind.kn}'];
        // 与主 tooltip K 块同口径：TOP→-1，BOTTOM→+1，未确认(UNKNOWN)→0；
        // 截断加"(截断)"。使副图 tooltip 行 / 副图读数框 与主 K 块一致（不再用 TOP/BOTTOM 串）。
        String v;
        if (fx == 'TOP') {
          v = '-1';
        } else if (fx == 'BOTTOM') {
          v = '1';
        } else {
          v = '0';
        }
        final truncated = sub['fractal_judgment_trunc_${ind.kn}'] == true;
        add(ind.label, truncated ? '$v(截断)' : v);
      }
      if (ind.kind == SubIndicatorKind.fractalPeakDist) {
        if (sub.containsKey('fractal_peak_dist_${ind.kn}')) {
          add(ind.label, sub['fractal_peak_dist_${ind.kn}']);
        } else if (ind.kn == 1) {
          // 回退：无 levels 时用旧 K0连线极点距
          add(ind.label, sub['fractal_peak_dist']);
        }
      }
      if (ind.kind == SubIndicatorKind.truncation) {
        // 截断触发当步：有 truncated 确认才显示方向值（level=kn）
        final confirms = row['level_confirms'];
        dynamic v;
        if (confirms is Map && confirms.containsKey(ind.kn)) {
          final c = confirms[ind.kn];
          if (c is LevelConfirm && c.truncated) {
            v = c.value;
          } else if (c is Map && c['truncated'] == true) {
            v = c['value'];
          }
        } else if (ind.kn == 1) {
          // 回退：无 levels 时用旧 k0_confirm 截断
          final bc = row['k0_confirm'];
          if (bc is Map && bc['truncated'] == true) {
            v = bc['value'];
          }
        }
        add(ind.label, v);
      }
      if (ind.kind == SubIndicatorKind.buy1) {
        final buy = sub['buy1_${ind.kn}'];
        final sell = sub['sell1_${ind.kn}'];
        if (buy != null || sell != null) {
          final parts = <String>[
            if (buy != null) '$buy',
            if (sell != null) '$sell',
          ];
          add(ind.label, parts.join(' '));
        } else {
          add(ind.label, null);
        }
      }
    }
    return lines;
  }

  /// Kn 块（K1=K0连线，K2=K1连线，…）；每层前加分隔线。
  List<CrosshairTooltipRow> _levelBlockRows(int idx) {
    final row = byIdx[idx];
    if (row == null) return const [];

    final snaps = row['levels'];
    final confirms = row['level_confirms'];
    final sub = row['sub'];
    final snapList = snaps is List<LevelSnap> ? snaps : const <LevelSnap>[];
    final total = totalLevels > snapList.length ? totalLevels : snapList.length;

    final lines = <CrosshairTooltipRow>[];
    for (var n = 1; n <= total; n++) {
      final snap = n - 1 < snapList.length ? snapList[n - 1] : null;
      // Kn 块「分型确认」= K(n+1) 端点确认（当步冻结）
      int? confirmVal;
      var confirmTruncated = false;
      if (confirms is Map) {
        final v = confirms[n + 1];
        if (v is LevelConfirm && (v.value == 1 || v.value == -1)) {
          confirmVal = v.value;
          confirmTruncated = v.truncated;
        }
      }
      // Kn 块「分型判断」：来自副图指标 indicator Kn分型判断（展示轨确认式打点）；
      // 照搬 分型确认 呈现（TOP→-1 / BOTTOM→+1，截断加"(截断)"，未确认为 0）
      // 须与副图指标「K{n}分型判断」同值：副图 kn=n+1，故读 fractal_judgment_${n+1}，非低一层的 $n
      int? judgeVal;
      var judgeTruncated = false;
      final fx = (sub is Map) ? sub['fractal_judgment_${n + 1}'] : null;
      if (fx == 'TOP') {
        judgeVal = -1;
      } else if (fx == 'BOTTOM') {
        judgeVal = 1;
      }
      if (judgeVal != null && sub is Map) {
        judgeTruncated = sub['fractal_judgment_trunc_${n + 1}'] == true;
      }
      // Kn 的 VOL 槽：用同层成交量序列替换预留位（不关心旧 unitVolume 是否对齐）
      final knVol = (sub is Map && sub['volume_$n'] is num)
          ? sub['volume_$n'] as num
          : null;
      lines.add(const CrosshairTooltipRow.separator());
      lines.addAll(_levelBlockRowsFor(
        n,
        snap,
        confirmVal,
        confirmTruncated,
        judgeVal,
        judgeTruncated,
        volumeOverride: knVol,
      ));
    }
    return lines;
  }

  /// 兼容旧调用：扁平 Kn 行。
  List<String> crosshairLevelLines(int idx) {
    return _levelBlockRows(idx)
        .where((e) => !e.isSeparator)
        .map((e) => e.flat)
        .toList();
  }

  List<CrosshairTooltipRow> _levelBlockRowsFor(
    int n,
    LevelSnap? snap,
    int? confirmVal,
    bool confirmTruncated,
    int? judgeVal,
    bool judgeTruncated, {
    num? volumeOverride,
  }) {
    final label = 'K$n';
    // 分型确认 / 分型判断 同一套呈现：±1(截断) / ±1 / 0（未确认）
    final confirmText = confirmVal == null
        ? '0'
        : (confirmTruncated ? '$confirmVal(截断)' : '$confirmVal');
    final judgeText = judgeVal == null
        ? '0'
        : (judgeTruncated ? '$judgeVal(截断)' : '$judgeVal');

    if (snap == null || snap.unitIdx == null) {
      return [
        CrosshairTooltipRow.kv('$label[No.]', '首K$n确认前'),
        CrosshairTooltipRow.kv(label, '—'),
        const CrosshairTooltipRow.starSeparator(),
        CrosshairTooltipRow.kv('$label合并$label序', '—'),
        CrosshairTooltipRow.kv('$label合并', '—'),
        CrosshairTooltipRow.kv('$label分型确认', CrosshairTooltipRow.boxNum(confirmText)),
        CrosshairTooltipRow.kv('$label分型判断', CrosshairTooltipRow.boxNum(judgeText)),
        const CrosshairTooltipRow.starSeparator(),
        ...knZsAfterKn[n] ?? const [],
      ];
    }

    return [
      CrosshairTooltipRow.kv('$label[No.]', CrosshairTooltipRow.boxNum(snap.unitIdx)),
      CrosshairTooltipRow.kv(
        label,
        CrosshairTooltipRow.boxNumInString(_fmtOhlcv(
          open: snap.unitOpen,
          high: snap.unitHigh,
          low: snap.unitLow,
          close: snap.unitClose,
          // 预留 VOL 槽：优先用 Kn成交量序列，否则回退 unitVolume
          volume: volumeOverride ?? snap.unitVolume,
        )),
      ),
      const CrosshairTooltipRow.starSeparator(),
      CrosshairTooltipRow.kv('$label合并$label序', CrosshairTooltipRow.boxNum(snap.mergeInnerSeq)),
      CrosshairTooltipRow.kv('$label合并组No.', snap.mergeBoxSeq >= 0 ? CrosshairTooltipRow.boxNum(snap.mergeBoxSeq) : '未成框'),
      CrosshairTooltipRow.kv(
        '$label合并',
        CrosshairTooltipRow.boxNumInString('H${_fmtPrice(snap.combineHigh)}/L${_fmtPrice(snap.combineLow)}'),
      ),
      CrosshairTooltipRow.kv('$label分型确认', CrosshairTooltipRow.boxNum(confirmText)),
      CrosshairTooltipRow.kv('$label分型判断', CrosshairTooltipRow.boxNum(judgeText)),
      const CrosshairTooltipRow.starSeparator(),
      ...knZsAfterKn[n] ?? const [],
    ];
  }

  /// 由确认列表生成逐 K 极点距（确认当步起算；不含极点 K；对齐副图/Rust）。
  static List<int> _peakDistSeries(int barCount, List<LevelConfirm> confirms) {
    final out = List<int>.filled(barCount, 0);
    if (barCount <= 0) return out;
    var ptr = 0;
    int? extreme;
    for (var i = 0; i < barCount; i++) {
      while (ptr < confirms.length && confirms[ptr].x <= i) {
        final c = confirms[ptr];
        if ((c.fx == 'TOP' || c.fx == 'BOTTOM') && c.poleX >= 0) {
          extreme = c.poleX;
        }
        ptr++;
      }
      out[i] = extreme == null ? 0 : i - extreme;
    }
    return out;
  }
}
