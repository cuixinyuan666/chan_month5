import 'dart:convert';
import 'dart:io';

import '../models/bar_crosshair_feature.dart';
import '../models/buy1_frame.dart';
import '../models/sell1_frame.dart';
import '../models/buy2_frame.dart';
import '../models/sell2_frame.dart';
import '../models/buy_n_frame.dart';
import '../models/sell_n_frame.dart';
import '../models/zs_frame.dart';
import '../models/k0_confirm_signal.dart';
import '../models/k0_line.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_frame.dart';
import '../models/level_models.dart';
import '../models/k1_analysis.dart';

/// 生成可复制页面快照（动态状态；历史见整合排查输出）。
/// 常驻功能：勿当临时调试代码删除；合并到 main 时必须保留。
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
    required String defaultK0Policy,
    required bool truncationCheck,
    required Set<String> subIndicatorLabels,
    required Set<String> mainIndicatorLabels,
    required List<KlineBar> visibleBars,
    required List<KlineCombineFrame> combineFrames,
    required List<K0ConfirmSignal> k0Confirms,
    required List<BarCrosshairFeature> barFeatures,
    required List<K0Line> k0Lines,
    required List<KlineCombineFrame> k1CombineFrames,
    required K1AnalysisBundle k1Analysis,
    required List<LevelBundle> levels,
    List<Buy1Frame> buy1K0Frames = const [],
    List<Sell1Frame> sell1K0Frames = const [],
    List<Buy2Frame> buy2K0Frames = const [],
    List<Sell2Frame> sell2K0Frames = const [],
    List<BuyNFrame> buyNK0Frames = const [],
    List<SellNFrame> sellNK0Frames = const [],
    String? lastError,
  }) {
    final now = DateTime.now();
    final ts =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

    final buf = StringBuffer();
    buf.writeln('CHAN_RUST chan_kline 页面快照');
    buf.writeln('时间=$ts');
    buf.writeln();

    buf.writeln('口径版本：chan_kline 命名/层级口径 v2026-07-15（K0/K1/…/KN 统一，术语表见 Obsidian 笔记 chan-month5/docs/GLOSSARY）；本快照仅含动态状态，历史见整合输出。');
    buf.writeln('【基础参数】');
    buf.writeln(
      '代码=${code ?? "-"}；周期=$periodLabel($period)；开始=$beginDate；结束=$endDate',
    );
    buf.writeln('数据目录=$dataRoot');
    buf.writeln('平台=${Platform.operatingSystem}');
    buf.writeln();

    buf.writeln('【逐K状态】');
    buf.writeln(
      'stepIdx=$stepIdx；可见K0=$visibleCount；总K0=$totalBars；播放=${playing ? "是" : "否"}',
    );
    if (visibleBars.isNotEmpty) {
      final tail = visibleBars.last;
      buf.writeln(
        '末根K0：idx=${tail.idx}；time=${tail.timeText}；'
        'O=${tail.open} H=${tail.high} L=${tail.low} C=${tail.close}',
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

    buf.writeln('【合并/K1/KN统计（字段名 k0_*/k1_*）】');
    buf.writeln(
      'K0合并框 combine_frames=${combineFrames.length}；'
      'K0分型确认 k0_confirms=${k0Confirms.length}；'
      'K0连线 k0_lines=${k0Lines.length}；'
      'bar_features=${barFeatures.length}',
    );
    final k1FxFrames =
        k1CombineFrames.where((f) => f.fx == 'TOP' || f.fx == 'BOTTOM').length;
    buf.writeln(
      'K1合并框 k1_combine_frames=${k1CombineFrames.length}（顶底分型=$k1FxFrames）；'
      'KN连线 k1_lines=${k1Analysis.k1Lines.length}；'
      'levels=${levels.length}',
    );
    buf.writeln();

    _writeLevels(buf, levels);
    _writeClass1Bs(buf, levels, buy1K0Frames, sell1K0Frames);
    _writeClass2Bs(buf, levels, buy2K0Frames, sell2K0Frames);
    _writeClassNBs(buf, levels, buyNK0Frames, sellNK0Frames);
    _writeZS(buf, levels);
    _writeDllDiag(buf, barFeatures, levels);
    _writeTailBarFeature(buf, visibleBars, barFeatures);
    _writeK0Confirms(buf, k0Confirms);
    _writeK0Lines(buf, k0Lines);

    if (lastError != null && lastError.trim().isNotEmpty) {
      buf.writeln('【最近错误】');
      buf.writeln(lastError.trim());
      buf.writeln();
    }


    buf.writeln('【复制说明】');
    buf.writeln(
      '请把本段全文粘贴给调试方；若排查确认/段冻结，请附带当前 stepIdx 与末根K0 idx。',
    );
    return buf.toString().trim();
  }

  static void _writeLevels(StringBuffer buf, List<LevelBundle> levels) {
    buf.writeln('【Kn流水线各层】');
    if (levels.isEmpty) {
      buf.writeln('（无 levels 输出）');
      buf.writeln();
      return;
    }
    for (final lv in levels) {
      final usedConfirms = lv.confirms.where((c) => c.used).length;
      // level 序号：1=K1，2=K2…
      buf.writeln(
        'K${lv.level}：policy=${lv.segmentPolicy}；'
        'confirms=${lv.confirms.length}（used=$usedConfirms）；'
        'segments=${lv.segments.length}；unit_bars=${lv.unitBars.length}；'
        'combine_frames=${lv.combineFrames.length}；'
        'first_dir=${lv.firstDir}@${lv.firstDirX}',
      );
      if (lv.activeUnit != null) {
        final u = lv.activeUnit!;
        buf.writeln(
          '  active_unit idx=${u.idx} dir=${u.dir} x=[${u.x1},${u.x2}]',
        );
      }
      final tailSeg = lv.segments.length <= 3
          ? lv.segments
          : lv.segments.sublist(lv.segments.length - 3);
      for (final s in tailSeg) {
        buf.writeln(
          '  seg idx=${s.idx} dir=${s.dir} '
          'begin=${s.beginConfirmX} end=${s.endConfirmX} '
          'seed_first=${s.idx == 0}',
        );
      }
    }
    buf.writeln();
  }

  /// 一类BS：会话冻结帧（排查步进消点 / 1Sa 口径）
  static void _writeClass1Bs(
    StringBuffer buf,
    List<LevelBundle> levels,
    List<Buy1Frame> buy1K0,
    List<Sell1Frame> sell1K0,
  ) {
    buf.writeln('【一类BS·会话冻结】');
    void dump(String kn, List<Buy1Frame> buys, List<Sell1Frame> sells) {
      if (buys.isEmpty && sells.isEmpty) {
        buf.writeln('$kn：buy=0 sell=0');
        return;
      }
      buf.writeln('$kn：buy=${buys.length} sell=${sells.length}');
      for (final p in buys) {
        buf.writeln(
          '  ${p.label} x=${p.x} price=${p.price} seg=${p.segIdx} zs=${p.zsSeq}',
        );
      }
      for (final p in sells) {
        buf.writeln(
          '  ${p.label} x=${p.x} price=${p.price} seg=${p.segIdx} zs=${p.zsSeq}',
        );
      }
    }

    dump('K0', buy1K0, sell1K0);
    for (final lv in levels) {
      dump('K${lv.level}', lv.buy1Frames, lv.sell1Frames);
    }
    buf.writeln();
  }

  /// 二类BS：会话冻结帧（与一类同框）
  static void _writeClass2Bs(
    StringBuffer buf,
    List<LevelBundle> levels,
    List<Buy2Frame> buy2K0,
    List<Sell2Frame> sell2K0,
  ) {
    buf.writeln('【二类BS·会话冻结】');
    void dump(String kn, List<Buy2Frame> buys, List<Sell2Frame> sells) {
      if (buys.isEmpty && sells.isEmpty) {
        buf.writeln('$kn：buy=0 sell=0');
        return;
      }
      buf.writeln('$kn：buy=${buys.length} sell=${sells.length}');
      for (final p in buys) {
        buf.writeln(
          '  ${p.label} x=${p.x} price=${p.price} seg=${p.segIdx} zs=${p.zsSeq}',
        );
      }
      for (final p in sells) {
        buf.writeln(
          '  ${p.label} x=${p.x} price=${p.price} seg=${p.segIdx} zs=${p.zsSeq}',
        );
      }
    }

    dump('K0', buy2K0, sell2K0);
    for (final lv in levels) {
      dump('K${lv.level}', lv.buy2Frames, lv.sell2Frames);
    }
    buf.writeln();
  }

  /// 三类+BS：会话冻结帧
  static void _writeClassNBs(
    StringBuffer buf,
    List<LevelBundle> levels,
    List<BuyNFrame> buyNK0,
    List<SellNFrame> sellNK0,
  ) {
    buf.writeln('【三类+BS·会话冻结】');
    void dump(String kn, List<BuyNFrame> buys, List<SellNFrame> sells) {
      if (buys.isEmpty && sells.isEmpty) {
        buf.writeln('$kn：buy=0 sell=0');
        return;
      }
      buf.writeln('$kn：buy=${buys.length} sell=${sells.length}');
      for (final p in buys) {
        buf.writeln(
          '  ${p.label} cls=${p.cls} x=${p.x} price=${p.price} seg=${p.segIdx} zs=${p.zsSeq}',
        );
      }
      for (final p in sells) {
        buf.writeln(
          '  ${p.label} cls=${p.cls} x=${p.x} price=${p.price} seg=${p.segIdx} zs=${p.zsSeq}',
        );
      }
    }

    dump('K0', buyNK0, sellNK0);
    for (final lv in levels) {
      dump('K${lv.level}', lv.buyNFrames, lv.sellNFrames);
    }
    buf.writeln();
  }

  static void _writeZS(StringBuffer buf, List<LevelBundle> levels) {
    buf.writeln('【中枢统计】');
    if (levels.isEmpty) {
      buf.writeln('（无 levels 输出）');
      buf.writeln();
      return;
    }
    for (final lv in levels) {
      buf.writeln(
        'K${lv.level}：中枢=${lv.zsFrames.length}',
      );
      void dumpZS(String tag, List<ZSFrame> frames) {
        for (var i = 0; i < frames.length; i++) {
          final f = frames[i];
          final seq = f.seq > 0 ? f.seq : (i + 1);
          buf.writeln(
            '  [$tag] #$seq count=${f.count} x=[${f.x1},${f.x2}] '
            'ZG/ZD=${f.high}/${f.low}'
            '${f.isSure ? '' : ' 不确定'}',
          );
        }
      }

      dumpZS('ZS', lv.zsFrames);
    }
    buf.writeln();
  }

  static void _writeDllDiag(
    StringBuffer buf,
    List<BarCrosshairFeature> barFeatures,
    List<LevelBundle> levels,
  ) {
    final hasLevels = levels.isNotEmpty;
    final hasLevelSnaps = barFeatures.any((f) => f.levels.isNotEmpty);
    buf.writeln(
      'DLL诊断：bar_features非空=${barFeatures.isNotEmpty}；'
      'bar_features条数=${barFeatures.length}；'
      'levels层数=${levels.length}；bar_features含LevelSnap=$hasLevelSnaps',
    );
    if (barFeatures.isNotEmpty &&
        barFeatures.every((f) => f.mergeCount == 1 && f.combineFx == 'UNKNOWN')) {
      buf.writeln('⚠ bar_features 可能仍为旧口径或数据过少，请确认 chan_ffi.dll 已更新');
    }
    if (!hasLevels && barFeatures.isNotEmpty) {
      buf.writeln('⚠ levels 为空但已有 bar_features，可能旧 DLL 或计算未产出 Kn 层');
    }
    buf.writeln();
  }

  static void _writeTailBarFeature(
    StringBuffer buf,
    List<KlineBar> visibleBars,
    List<BarCrosshairFeature> barFeatures,
  ) {
    buf.writeln('【末K0十字线特征（ML口径）】');
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
        'k1_idx=${feat.k1Idx}；k1_combine_fx=${feat.k1CombineFx}',
      );
      if (feat.levels.isNotEmpty) {
        buf.writeln('  levels快照:');
        for (final snap in feat.levels) {
          buf.writeln(
            '    K${snap.level} unit=${snap.unitIdx} dir=${snap.unitDir} '
            'x=[${snap.unitX1},${snap.unitX2}] merge=${snap.mergeCount} fx=${snap.combineFx}',
          );
        }
      }
    }
    buf.writeln();
  }

  static void _writeK0Confirms(StringBuffer buf, List<K0ConfirmSignal> signals) {
    buf.writeln('【K0分型确认最近8条】');
    if (signals.isEmpty) {
      buf.writeln('（无）');
      buf.writeln();
      return;
    }
    final tail = signals.length <= 8 ? signals : signals.sublist(signals.length - 8);
    for (final s in tail) {
      buf.writeln(
        'x=${s.x} fx=${s.fx} value=${s.value} fractal=(${s.fractalX1},${s.fractalX2})'
        '${s.truncated ? " truncated" : ""}',
      );
    }
    buf.writeln();
  }

  static void _writeK0Lines(StringBuffer buf, List<K0Line> segments) {
    buf.writeln('【K0连线最近5条】');
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

  /// 紧凑 JSON 片段（便于对比 Rust 输出字段）。
  static String buildLevelsJsonTail({
    required List<LevelBundle> levels,
    int confirmTail = 4,
  }) {
    final map = <String, dynamic>{
      'levels': levels
          .map((lv) => {
                'level': lv.level,
                'segment_policy': lv.segmentPolicy,
                'confirms_tail': lv.confirms.length <= confirmTail
                    ? lv.confirms
                        .map((c) => {
                              'x': c.x,
                              'fx': c.fx,
                              'used': c.used,
                            })
                        .toList()
                    : lv.confirms
                        .sublist(lv.confirms.length - confirmTail)
                        .map((c) => {
                              'x': c.x,
                              'fx': c.fx,
                              'used': c.used,
                            })
                        .toList(),
                'segments': lv.segments.length,
                'unit_bars': lv.unitBars.length,
              })
          .toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(map);
  }

  static String _shortTime(DateTime t) {
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
  }
}
