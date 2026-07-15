import 'dart:convert';
import 'dart:io';

import '../models/bar_crosshair_feature.dart';
import '../models/k0_confirm_signal.dart';
import '../models/k0_line.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_frame.dart';
import '../models/level_models.dart';
import '../models/k1_analysis.dart';
import 'msg_history.dart';

/// 生成可复制页面快照（含最近历史记录，便于粘贴排查）。
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

    buf.writeln('【命名与口径】');
    buf.writeln(
      '层级：K0=原始K，K1=K0连线，K2=K1连线，Kn=第n层；旧「n段」=Kn；'
      '主图/副图统一层号：指标 kn=层号(1..maxKn)，展示名比层号小1（主图 K(n-1)连线/K(n-1)合并；'
      '副图 K(n-1)分型确认/K(n-1)分型极点距/K(n-1)截断）；旧「笔连线」=K0连线（曾称K1连线），线段=K1连线；合并不偏移。',
    );
    buf.writeln(
      'Kn流水线：K(n-1)→包含合并→三元素分型确认→锚定配对→Kn；'
      '全层同构：必须等下层单元确认冻结后才能参与上层（含截断）；'
      '逐K当下冻结，未来结构不回写旧标签。',
    );
    buf.writeln(
      '十字线 tooltip 走 bar_features.levels[] 各层 LevelSnap；'
      '进行中单元可只读探测上层合并态（仅展示）；主图连线可含末态展示修正。'
      '十字线开启时：K0合并/K1合并/Kn跨段中枢与逐步口径对齐，本地 as-of 重算框；'
      '关闭十字线仍画 Rust 末态 frames。',
    );
    buf.writeln(
      '十字线 tooltip：两列表格对齐（日期时间/K0/Kn 分层，==== 分隔）；'
      '半透明底不挡 K 线；内容过长滚轮下翻；'
      '显示 tooltip 时滚轮不缩放，仅十字线(关tooltip)时滚轮可缩放。'
      '十字线双击三态（仅中间1/3热区自管双击；左右不走系统双击）：'
      '①开十字线+价格标签+tooltip；'
      '②关 tooltip（线与价格标签保留）；③全关并恢复鼠标抓取。'
      '十字线激活期间：屏蔽左步退/右步进/中播放及长按复位·重载·跑到末尾，'
      '点击仅跟线；仅中间双击可切三态。非十字线态：左/右点击立刻步退/步进，连点即加速。',
    );
    buf.writeln(
      '副图目录：成交量 + Kn分型确认/极点距；Kn截断仅 truncation_check=开 时可选；'
      '极点距数值不画在折线上，十字线激活时在副图右上角固定读数。',
    );
    buf.writeln(
      '首段策略 default_k0_policy=$defaultK0Policy（pending/retained/purged）；'
      '截断机制 truncation_check=${truncationCheck ? "开" : "关"}。',
    );
    buf.writeln(
      '命名变更（2026-07-15）：中枢(ZS) 已统一更名为跨段中枢(KuaDuan)；'
      '主图指标 ZS→跨段中枢框，展示名 K(n-1)跨段中枢（笔跨段中枢=K0跨段中枢，线段跨段中枢=K1跨段中枢）；'
      'Rust 模块 zs→kuaduan（ZS→KuaDuan、ZSFrame→KuaDuanFrame、zs_frames→kuaduan_frames），已重建 chan_ffi.dll；JSON key 同步变更。',
    );
    buf.writeln(
      '命名变更（2026-07-15）：代码取消「笔/线段」概念，统一 K0/K1/…/KN。'
      '笔=K0连线、线段=K1连线；笔虚拟K=K1、线段虚拟K=K2。'
      '字段 bi_*→k0_*/k1_*、seg_*→k1_*（如 bi_segments→k0_lines、bi_combine_frames→k1_combine_frames、seg_lines→k1_lines）；'
      'Rust 类型 BiSegment→K0Line、BiVirtualBar→K1Bar、SegLine→K1Line、SegAnalysisBundle→K1AnalysisBundle 等；'
      '已重建 chan_ffi.dll；JSON key 同步变更。内部 level 1-based 不变；泛用 segment 英文词（LevelSegment/segments/segment_policy）保留。',
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
    _writeKuaDuan(buf, levels);
    _writeDllDiag(buf, barFeatures, levels);
    _writeTailBarFeature(buf, visibleBars, barFeatures);
    _writeK0Confirms(buf, k0Confirms);
    _writeK0Lines(buf, k0Lines);

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
      if (lv.pendingUnit != null) {
        final u = lv.pendingUnit!;
        buf.writeln(
          '  pending_unit idx=${u.idx} dir=${u.dir} x=[${u.x1},${u.x2}]',
        );
      }
      final tailSeg = lv.segments.length <= 3
          ? lv.segments
          : lv.segments.sublist(lv.segments.length - 3);
      for (final s in tailSeg) {
        buf.writeln(
          '  seg idx=${s.idx} dir=${s.dir} '
          'begin=${s.beginConfirmX} end=${s.endConfirmX} '
          'promoted=${s.isPromotedDefault}',
        );
      }
    }
    buf.writeln();
  }

  static void _writeKuaDuan(StringBuffer buf, List<LevelBundle> levels) {
    buf.writeln('【跨段中枢统计】');
    if (levels.isEmpty) {
      buf.writeln('（无 levels 输出）');
      buf.writeln();
      return;
    }
    for (final lv in levels) {
      buf.writeln(
        'K${lv.level}：跨段中枢框 kuaduan_frames=${lv.kuaduanFrames.length}',
      );
      // 列出本层各框序号·段数与 x 区间，便于核对合并/延伸
      for (var i = 0; i < lv.kuaduanFrames.length; i++) {
        final f = lv.kuaduanFrames[i];
        final seq = f.seq > 0 ? f.seq : (i + 1);
        buf.writeln(
          '  #$seq count=${f.count} x=[${f.x1},${f.x2}] ZD/ZG=${f.high}/${f.low}',
        );
      }
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
