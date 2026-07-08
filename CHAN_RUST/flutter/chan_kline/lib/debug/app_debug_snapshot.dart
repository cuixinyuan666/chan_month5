import 'dart:convert';
import 'dart:io';

import '../models/bar_crosshair_feature.dart';
import '../models/bi_confirm_signal.dart';
import '../models/bi_segment.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_frame.dart';
import '../models/seg_analysis.dart';
import 'msg_history.dart';

/// 生成可复制页面调试快照（对齐 a_replay_trainer「复制配置」思路）。
class AppDebugSnapshot {
  static String build({
    required String dataRoot,
    required String? code,
    required String period,
    required String periodLabel,
    required String beginDate,
    required String endDate,
    required int stepIdx,
    required int totalBars,
    required int visibleCount,
    required bool playing,
    required Set<String> subIndicatorLabels,
    required Set<String> mainIndicatorLabels,
    required List<KlineBar> visibleBars,
    required List<KlineCombineFrame> combineFrames,
    required List<BiConfirmSignal> biConfirms,
    required List<BarCrosshairFeature> barFeatures,
    required List<BiSegment> biSegments,
    required List<KlineCombineFrame> biCombineFrames,
    required SegAnalysisBundle segAnalysis,
    String? lastError,
  }) {
    final now = DateTime.now();
    final ts =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

    final buf = StringBuffer();
    buf.writeln('CHAN_RUST chan_kline 页面调试快照');
    buf.writeln('时间=$ts');
    buf.writeln();

    buf.writeln('【已知问题 / 调试提示】');
    buf.writeln(
      '段确认：合并笔K线分型；方案A=进行中笔K逐K喂入，可早于整笔确认；副图±1柱@x；已冻结分型不回写。'
      '与笔确认不同层——笔确认看1分钟K合并，段确认看笔K线合并后的顶/底。',
    );
    buf.writeln(
      '同一步K上笔确认fx与段确认fx可相反（段确认x=触发笔的end_confirm_x，fx=合并笔K中间分型）。',
    );
    buf.writeln(
      '合并fx/合并数：十字线应走 bar_features 逐步口径；主图 combine frame 的 fx/count 仅展示末态。',
    );
    buf.writeln(
      '主图笔/段连线：展示用，可含未来修正，不参与 ML/回测。',
    );
    buf.writeln();

    buf.writeln('【基础参数】');
    buf.writeln(
      '代码=${code ?? "-"}；周期=$periodLabel($period)；开始=$beginDate；结束=$endDate',
    );
    buf.writeln('数据目录=$dataRoot');
    buf.writeln('平台=${Platform.operatingSystem}');
    buf.writeln();

    buf.writeln('【逐K状态】');
    buf.writeln(
      'stepIdx=$stepIdx；可见K=$visibleCount；总K=$totalBars；播放=${playing ? "是" : "否"}',
    );
    if (visibleBars.isNotEmpty) {
      final tail = visibleBars.last;
      buf.writeln(
        '末根K：idx=${tail.idx}；time=${tail.timeText}；O=${tail.open} H=${tail.high} L=${tail.low} C=${tail.close}',
      );
    }
    buf.writeln();

    buf.writeln('【副图勾选】');
    buf.writeln(
      subIndicatorLabels.isEmpty ? '（无）' : subIndicatorLabels.join('、'),
    );
    buf.writeln();

    buf.writeln('【主图勾选】');
    buf.writeln(
      mainIndicatorLabels.isEmpty ? '（无）' : mainIndicatorLabels.join('、'),
    );
    buf.writeln();

    buf.writeln('【合并/笔/段统计】');
    buf.writeln(
      'combine_frames=${combineFrames.length}；bi_confirms=${biConfirms.length}；'
      'bi_segments=${biSegments.length}；bar_features=${barFeatures.length}',
    );
    final biFxFrames =
        biCombineFrames.where((f) => f.fx == 'TOP' || f.fx == 'BOTTOM').length;
    buf.writeln(
      'bi_combine_frames=${biCombineFrames.length}（顶底分型=$biFxFrames）；'
      'seg_confirms=${segAnalysis.segConfirms.length}；seg_lines=${segAnalysis.segLines.length}',
    );
    buf.writeln(
      'first_seg_signals=${segAnalysis.firstSegDirSignals.length}；'
      'bar_sub_snapshots=${segAnalysis.barSubSnapshots.length}',
    );
    buf.writeln(
      'seg_building_dir=${segAnalysis.buildingSegDir}；seg_first_seg_dir=${segAnalysis.firstSegDir}',
    );
    _writeDllDiag(buf, barFeatures, segAnalysis, biSegments.length);
    buf.writeln();

    _writeTailBarFeature(buf, visibleBars, barFeatures);
    _writeBiConfirms(buf, biConfirms);
    _writeBiSegments(buf, biSegments);
    _writeBiVsSegCompare(buf, biConfirms, biSegments, biCombineFrames, segAnalysis, visibleBars);
    _writeSegAnalysis(buf, segAnalysis, visibleBars);

    if (lastError != null && lastError.trim().isNotEmpty) {
      buf.writeln('【最近错误】');
      buf.writeln(lastError.trim());
      buf.writeln();
    }

    final hist = MsgHistory.instance.rows;
    if (hist.isNotEmpty) {
      buf.writeln('【历史记录最近10条】');
      final tail = hist.length <= 10 ? hist : hist.sublist(hist.length - 10);
      for (final e in tail) {
        buf.writeln('[${_shortTime(e.time)}] ${e.text}');
      }
      buf.writeln();
    }

    buf.writeln('【复制说明】');
    buf.writeln('请把本段全文粘贴给调试方；若排查段确认，请附带当前 stepIdx 与末根K idx。');
    return buf.toString().trim();
  }

  /// 紧凑 JSON 片段（便于对比 Rust 输出字段）。
  static String buildJsonTail({
    required SegAnalysisBundle segAnalysis,
    required List<BarCrosshairFeature> barFeatures,
    int barFeatureTail = 3,
    int snapshotTail = 5,
  }) {
    final map = <String, dynamic>{
      'eigen_frames': segAnalysis.eigenFrames
          .map((f) => {
                'slot': f.slot,
                'x1': f.x1,
                'x2': f.x2,
                'fx': f.fx,
                'high': f.high,
                'low': f.low,
              })
          .toList(),
      'seg_confirms': segAnalysis.segConfirms
          .map((s) => {
                'x': s.x,
                'fx': s.fx,
                'value': s.value,
                'fractal_x1': s.fractalX1,
                'fractal_x2': s.fractalX2,
                'fractal_high': s.fractalHigh,
                'fractal_low': s.fractalLow,
                'peak_bi_idx': s.peakBiIdx,
              })
          .toList(),
      'bar_sub_snapshots': segAnalysis.barSubSnapshots.length <= snapshotTail
          ? segAnalysis.barSubSnapshots
              .map((s) => {
                    'idx': s.idx,
                    'building_seg_dir': s.buildingSegDir,
                    'first_seg_dir': s.firstSegDir,
                    'seg_confirm': s.segConfirm,
                  })
              .toList()
          : segAnalysis.barSubSnapshots
              .sublist(segAnalysis.barSubSnapshots.length - snapshotTail)
              .map((s) => {
                    'idx': s.idx,
                    'building_seg_dir': s.buildingSegDir,
                    'first_seg_dir': s.firstSegDir,
                    'seg_confirm': s.segConfirm,
                  })
              .toList(),
      'bar_features_tail': barFeatures.length <= barFeatureTail
          ? barFeatures
              .map((f) => {
                    'idx': f.idx,
                    'merge_count': f.mergeCount,
                    'combine_fx': f.combineFx,
                    'merge_inner_seq': f.mergeInnerSeq,
                    'fractal_peak_dist': f.fractalPeakDist,
                  })
              .toList()
          : barFeatures
              .sublist(barFeatures.length - barFeatureTail)
              .map((f) => {
                    'idx': f.idx,
                    'merge_count': f.mergeCount,
                    'combine_fx': f.combineFx,
                    'merge_inner_seq': f.mergeInnerSeq,
                    'fractal_peak_dist': f.fractalPeakDist,
                  })
              .toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(map);
  }

  static void _writeDllDiag(
    StringBuffer buf,
    List<BarCrosshairFeature> barFeatures,
    SegAnalysisBundle segAnalysis,
    int biSegmentCount,
  ) {
    final hasSegSnap = segAnalysis.barSubSnapshots.isNotEmpty;
    buf.writeln(
      'DLL诊断：bar_features非空=${barFeatures.isNotEmpty}；'
      'bar_features条数=${barFeatures.length}；seg_analysis快照非空=$hasSegSnap',
    );
    if (barFeatures.isNotEmpty && barFeatures.every((f) => f.mergeCount == 1 && f.combineFx == 'UNKNOWN')) {
      buf.writeln('⚠ bar_features 可能仍为旧口径或数据过少，请确认 chan_ffi.dll 已更新');
    }
    if (biSegmentCount > 0 && !hasSegSnap) {
      buf.writeln('⚠ 有笔段但 seg_analysis 为空：可能旧 DLL 或段分析未产出');
    }
  }


  static void _writeTailBarFeature(
    StringBuffer buf,
    List<KlineBar> visibleBars,
    List<BarCrosshairFeature> barFeatures,
  ) {
    buf.writeln('【末K十字线特征（ML口径）】');
    if (visibleBars.isEmpty || barFeatures.isEmpty) {
      buf.writeln('（无）');
      buf.writeln();
      return;
    }
    final idx = visibleBars.last.idx;
    BarCrosshairFeature? feat;
    for (final f in barFeatures) {
      if (f.idx == idx) {
        feat = f;
        break;
      }
    }
    feat ??= barFeatures.isNotEmpty ? barFeatures.last : null;
    if (feat == null) {
      buf.writeln('（未找到）');
    } else {
      buf.writeln(
        'idx=${feat.idx}；weekday=${feat.weekday}；merge_inner_seq=${feat.mergeInnerSeq}；'
        'merge_count=${feat.mergeCount}；combine_fx=${feat.combineFx}；'
        'combine_h/l=${feat.combineHigh}/${feat.combineLow}；'
        'fractal_peak_dist=${feat.fractalPeakDist}',
      );
      if (feat.biIdx != null) {
        buf.writeln(
          'bi_idx=#${feat.biIdx}；bi_merge_inner_seq=${feat.biMergeInnerSeq}；'
          'bi_o/h/l/c/vol=${feat.biOpen}/${feat.biHigh}/${feat.biLow}/'
          '${feat.biClose}/${feat.biVolume}；'
          'bi_combine_h/l=${feat.biCombineHigh}/${feat.biCombineLow}',
        );
      }
    }
    buf.writeln();
  }

  static void _writeBiConfirms(StringBuffer buf, List<BiConfirmSignal> signals) {
    buf.writeln('【笔确认最近8条】');
    if (signals.isEmpty) {
      buf.writeln('（无）');
      buf.writeln();
      return;
    }
    final tail = signals.length <= 8 ? signals : signals.sublist(signals.length - 8);
    for (final s in tail) {
      buf.writeln(
        'x=${s.x} fx=${s.fx} value=${s.value} fractal=(${s.fractalX1},${s.fractalX2})',
      );
    }
    buf.writeln();
  }

  static void _writeBiSegments(StringBuffer buf, List<BiSegment> segments) {
    buf.writeln('【笔段最近5条】');
    if (segments.isEmpty) {
      buf.writeln('（无）');
      buf.writeln();
      return;
    }
    final tail =
        segments.length <= 5 ? segments : segments.sublist(segments.length - 5);
    for (final s in tail) {
      buf.writeln(
        'idx=${s.idx} dir=${s.dir} begin=${s.beginConfirmX} end=${s.endConfirmX} '
        'prev=${s.prevIdx} next=${s.nextIdx}',
      );
    }
    buf.writeln();
  }

  /// 笔确认 vs 段确认对照（同口径逐步核对）。
  static void _writeBiVsSegCompare(
    StringBuffer buf,
    List<BiConfirmSignal> biConfirms,
    List<BiSegment> biSegments,
    List<KlineCombineFrame> biCombineFrames,
    SegAnalysisBundle seg,
    List<KlineBar> visibleBars,
  ) {
    buf.writeln('【笔确认 vs 段确认对照】');
    final biFxCount =
        biCombineFrames.where((f) => f.fx == 'TOP' || f.fx == 'BOTTOM').length;
    buf.writeln(
      '笔确认=${biConfirms.length}；段确认=${seg.segConfirms.length}；'
      '合并笔K顶底分型=$biFxCount（段确认应与之相等）',
    );
    if (biFxCount > seg.segConfirms.length) {
      buf.writeln('⚠ 段确认条数少于合并笔K顶底分型，请检查 DLL / 计算口径');
    } else if (biFxCount < seg.segConfirms.length) {
      buf.writeln(
        '✓ 段确认已覆盖合并笔K顶底分型（方案A另有'
        '${seg.segConfirms.length - biFxCount}条更早冻结分型）',
      );
    } else {
      buf.writeln('✓ 段确认条数与合并笔K顶底分型一致');
    }

    BiConfirmSignal? biAt(int x) {
      for (final c in biConfirms) {
        if (c.x == x) return c;
      }
      return null;
    }

    final tailSeg = seg.segConfirms.length <= 6
        ? seg.segConfirms
        : seg.segConfirms.sublist(seg.segConfirms.length - 6);
    buf.writeln('最近段确认（x=触发笔end_confirm_x；fractal=合并笔K分型区间）：');
    for (final s in tailSeg) {
      final bi = s.peakBiIdx >= 0 && s.peakBiIdx < biSegments.length
          ? biSegments[s.peakBiIdx]
          : null;
      final bc = biAt(s.x);
      final t = _timeAtBarIdx(visibleBars, s.x);
      final fxNote = bc == null
          ? '同K无笔确认'
          : bc.fx == s.fx
              ? '同K笔确认fx一致'
              : '同K笔确认fx=${bc.fx}（不同层正常）';
      buf.writeln(
        '  x=${s.x} time=${t ?? "?"} seg_fx=${s.fx} fractal=(${s.fractalX1},${s.fractalX2}) '
        'peak_bi=${s.peakBiIdx} | $fxNote',
      );
      if (bi != null) {
        buf.writeln(
          '    触发笔 idx=${bi.idx} dir=${bi.dir} end=${bi.endConfirmX}',
        );
      }
    }

    final lastSegX =
        seg.segConfirms.isEmpty ? -1 : seg.segConfirms.last.x;
    final pendingBi = biConfirms.where((c) => c.x > lastSegX).toList();
    if (pendingBi.isNotEmpty) {
      buf.writeln('末次段确认后笔确认（尚未形成合并笔K新分型）：');
      for (final c in pendingBi) {
        buf.writeln(
          '  x=${c.x} fx=${c.fx} fractal=(${c.fractalX1},${c.fractalX2})',
        );
      }
      final pendingFrame = biCombineFrames.isNotEmpty &&
              (biCombineFrames.last.fx == 'UNKNOWN')
          ? biCombineFrames.last
          : null;
      if (pendingFrame != null) {
        buf.writeln(
          '  → 当前合并笔K末框 x=[${pendingFrame.x1},${pendingFrame.x2}] '
          'count=${pendingFrame.count} fx=${pendingFrame.fx}（待第三元素分型）',
        );
      }
    }
    buf.writeln();
  }

  static void _writeSegAnalysis(
    StringBuffer buf,
    SegAnalysisBundle seg,
    List<KlineBar> visibleBars,
  ) {
    buf.writeln('【段分析 / 合并笔K线段确认】');
    if (seg.segConfirms.isEmpty) {
      buf.writeln('seg_confirms=（空）');
    } else {
      if (visibleBars.isNotEmpty) {
        final first = seg.segConfirms.first;
        final t = _timeAtBarIdx(visibleBars, first.x);
        buf.writeln('首段确认 idx=${first.x} time=${t ?? "?"} fx=${first.fx}');
      }
      buf.writeln('seg_confirms:');
      for (final s in seg.segConfirms) {
        buf.writeln(
          '  x=${s.x} fx=${s.fx} value=${s.value} ended_dir=${s.endedSegDir} '
          'fractal=(${s.fractalX1},${s.fractalX2}) H=${s.fractalHigh} L=${s.fractalLow}',
        );
      }
    }
    if (seg.firstSegDirSignals.isNotEmpty) {
      buf.writeln('first_seg_dir_signals:');
      for (final s in seg.firstSegDirSignals) {
        buf.writeln('  x=${s.x} dir=${s.dir}');
      }
    }
    if (visibleBars.isNotEmpty && seg.barSubSnapshots.isNotEmpty) {
      final idx = visibleBars.last.idx;
      final snap = seg.snapshotAt(idx);
      buf.writeln('末K段快照 idx=$idx → ${snap == null ? "无" : _fmtSnap(snap)}');
      final tail = seg.barSubSnapshots.length <= 3
          ? seg.barSubSnapshots
          : seg.barSubSnapshots.sublist(seg.barSubSnapshots.length - 3);
      buf.writeln('bar_sub_snapshots末3条:');
      for (final s in tail) {
        buf.writeln('  ${_fmtSnap(s)}');
      }
    } else {
      buf.writeln('bar_sub_snapshots=（空）');
    }
    buf.writeln();
    buf.writeln('【段分析 JSON 尾段】');
    buf.writeln(
      buildJsonTail(
        segAnalysis: seg,
        barFeatures: const [],
        barFeatureTail: 0,
        snapshotTail: 5,
      ),
    );
    buf.writeln();
  }

  static String _fmtSnap(BarSubSnapshot s) {
    return 'idx=${s.idx} building=${s.buildingSegDir} first=${s.firstSegDir} '
        'confirm=${s.segConfirm}';
  }

  static String? _timeAtBarIdx(List<KlineBar> bars, int idx) {
    for (final b in bars) {
      if (b.idx == idx) return b.timeText;
    }
    if (idx >= 0 && idx < bars.length) return bars[idx].timeText;
    return null;
  }

  static String _shortTime(DateTime t) {
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
  }
}
