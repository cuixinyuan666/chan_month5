import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../compute/chart_view_compute.dart';
import '../models/fractal_judgment_event.dart';
import '../models/k1_bar.dart';

/// 消息历史（对齐 a_replay_trainer 的 appendMsgHistory / 一键复制）。
/// 常驻功能：放在 lib/history/，合并到 main / 清理 UI 时不得删除。
class MsgHistory {
  MsgHistory._();

  static final MsgHistory instance = MsgHistory._();

  static const int _maxRows = 500;

  /// 命名变更是否已记录（进程内只记一次，便于从历史记录追溯完整更名过程）
  static bool _namingRenameLogged = false;

  /// 种子框首段口径是否已记录（进程内去重）
  static bool _seedBoxFirstLogged = false;

  /// test 自定义 OHLC 口径是否已记录（进程内去重）
  static bool _testCustomOhlcLogged = false;

  final List<MsgHistoryEntry> _rows = [];

  List<MsgHistoryEntry> get rows => List.unmodifiable(_rows);

  void append(String text) {
    final content = text.trim();
    if (content.isEmpty) return;
    if (_rows.isNotEmpty && _rows.last.text == content) return;
    _rows.add(MsgHistoryEntry(
      time: DateTime.now(),
      text: content,
    ));
    while (_rows.length > _maxRows) {
      _rows.removeAt(0);
    }
  }

  void clear({String? reason}) {
    _rows.clear();
    if (reason != null && reason.trim().isNotEmpty) {
      append('历史记录已清空：$reason');
    }
  }

  /// 记录「跨段中枢 v1 + 原生中枢(ZS)」命名变更（进程内去重一次），
  /// 便于调试时从历史记录追溯名称演进的完整过程。
  void appendNamingRename() {
    if (_namingRenameLogged) return;
    _namingRenameLogged = true;
    append(
      '【命名变更】跨段中枢 v1 + 原生中枢(ZS)：'
      'Rust 模块跨段中枢 KuaDuan→KuaDuanV1（KuaDuan→KuaDuanV1、KuaDuanFrame→KuaDuanV1Frame，'
      'kuaduan_frames JSON key 保持不变）；新增原生缠论中枢 ZS（ZS/ZSFrame，JSON key zs_frames），'
      '由 Rust find_zs 在每层已冻结段上全层同构计算（≥3 连续重叠成中枢、离开-返回延伸、九段升级、combine 合并），'
      '不引入 Python 式「笔」、不改动已有形态学元素逻辑；已重建 chan_ffi.dll；'
      '主图指标新增「K(n-1)原生中枢」（K0原生中枢、K1原生中枢），与跨段中枢同层同号、独立色系。',
    );
    append(
      '【命名变更】笔/线段 → K0连线/K1连线：代码取消「笔/线段」概念，统一 K0/K1/…/KN。'
      '笔=K0连线、线段=K1连线、笔虚拟K=K1；字段 bi_*→k0_*/k1_*、seg_*→k1_*'
      '（bi_segments→k0_lines、bi_combine_frames→k1_combine_frames、seg_lines→k1_lines）；'
      'Rust 类型 BiSegment→K0Line、BiVirtualBar→K1Bar、SegLine→K1Line、SegAnalysisBundle→K1AnalysisBundle；'
      '已重建 chan_ffi.dll；JSON key 同步变更。',
    );
    append(
      '【命名变更】三类买卖点（BSP）：新增 Rust 模块 bsp（BSP/BSPConfig/BSPFrame，JSON key bsp_frames），'
      '由 find_bsp 在每层已冻结段 + 同层原生中枢(ZS) 上全层同构计算；'
      '背驰策略（用户决策）：纯结构趋势末端，不做 MACD/力度背驰——'
      '一类=≥min_zs_cnt 个中枢构成趋势的末段端点，二类=一类后回踩不破一类极值，三类=一类后离开返回但不回中枢带[ZG,ZD]；'
      '不引入 Python 式「笔」、不改动已有形态学元素逻辑；已重建 chan_ffi.dll；'
      '主图指标新增「K(n-1)买卖点」（K0买卖点、K1买卖点），与跨段中枢/原生中枢同层同号、买红卖绿、'
      '一类圆/二类三角/三类菱形区分。',
    );
  }

  /// 记录「构建中合并框（虚线）」特性：每层 combineFrames 末组=仍可 absorb 的构建中合并（虚线），
  /// 前组=已冻结合并（实线）；全层同构。注意：信号是合并引擎末组，不是 activeUnit（那是进行中段）。
  void appendBuildingCombineFrame() {
    append(
      '【新增特性】构建中合并框（虚线）：主图每层合并框把 CombineEngine.groups 末组画成虚线，'
      '表示「仍可能继续包含合并、尚未被下一组顶掉的构建中合并」；前组实线=已冻结。'
      '全层同构（K0/K1/…/KN 均对应该层 combineFrames 末项）；'
      '虚线语言与构建中连线一致。口径纠正：不取 activeUnit（activeUnit=进行中段/连线单元，不是合并组）；'
      '十字线 as-of 时用当步重建的 combineFrames，末组仍虚线（当下性由 as-of 重建保证）。'
      '【排障】首屏仅 1 根 K 时若 xSpan 塌成 1e-6，虚线描边会循环卡死白屏——已将 xSpan 下限改为 1.0。',
    );
  }

  /// 构建中连线虚线尾端：扫价区间内首次方向极值所在 K0（全层同构）。
  void appendBuildingDashTailFirstExtreme() {
    append(
      '【画线口径】KN/K0 构建中虚线尾端「价」(X,Y)：取扫价区间 (确认当步, as-of] 内'
      '方向极值首次出现的那根 K0（升=首个 max(high)，降=首个 min(low)；'
      '区间仅1根则落该根；空区间退化为 asOf 本根）。'
      '不再把 X 钉在 as-of/末根而 Y 取区间极值。全层同构（K0/K1/…/KN 共用 buildingTailEndpoint）。'
      '冻结实线端点仍走 fx_pole_x/pole_x，未改。',
    );
  }

  /// 展示轨动态 KN 合并框：冻+进行中/pending 喂合并引擎；永久结构不回写。
  void appendDisplayTrackDynamicKnCombine() {
    append(
      '【画线口径】展示轨动态 KN 合并框（方案2）：主图 K1/Kn 合并框由'
      '冻结单元+进行中/pending 虚拟单元重算（与 level_virtual_units / '
      'asOfLevelVirtualK1Bars 同输入）；末组虚线=构建中合并可继续 absorb。'
      '永久 feed/propagate/ZS/BSP 仍只认冻结，不回写旧标签。'
      'K0 合并本就整段入框，行为同构。十字线 as-of 同步含进行中。'
      '动态连线见 appendDisplayTrackDynamicKnBuildingLines（同虚拟单元输入）。',
    );
  }

  /// 主图「KN合并」拆为「KN合并」(仅合并框) 与「KN」(仅淡实体线) 两项：
  /// 合并指标各层(K0/K1/…/KN)均不再附带淡实体线（全层同构）；
  /// 因单一「KN」会一次画出所有层淡实体、与单层合并框不对齐，改为按层独立成项
  /// K0/K1/K2…（层号与合并/连线同号），勾选单层只画该层淡实体，与对应合并框一一对齐。
  void appendKnSplit() {
    append(
      '【指标拆分】主图「KN合并」拆为两项：①「KN合并」=原合并框；②「KN」=原淡实体线。'
      '拆分全层同构：各层 K0合并/K1合并/Kn合并 均只画合并框，不再附带底层淡实体线。'
      '初版「KN」为单一指标（不分 K0/K1/…），但一次画出所有层淡实体、与单层合并框不对齐；'
      '改为按层独立成项 K0/K1/K2…（层号与合并/连线同号）：勾选「K1」只画 K1 淡蜡烛、'
      '勾选「K2」只画 K2 单元淡实体，与对应「K(n-1)合并」框一一对齐。'
      'K0 原始蜡烛改为由「K0」项独立控制（可关闭/显示），不再是恒显底图；'
      '取消勾选「K0」即隐藏原生蜡烛，仅留合并框/连线等叠加层。',
    );
  }

  /// 键盘方向键交互：十字线态=十字线左右移；非十字线态=左步退/右步进。
  void appendKeyboardNav() {
    append(
      '【键盘交互】主图支持方向键 ←/→：'
      '十字线激活时 → 左/右方向键令十字线竖线吸附相邻 K 线中心（左右移一格）；'
      '未激活时 → 左=步退、右=步进（与点击左/右热区同义）。'
      '实现：KlineChart 用 HardwareKeyboard.instance.addHandler(_handleHardwareKey) '
      '全局监听（initState 注册、dispose 注销）；十字线激活→_moveCrosshairBy 左右移，'
      '未激活→调用现有 onTapStepBack/onTapStepForward；方向键返回 true 拦截默认滚动。',
    );
  }

  /// 展示轨分型判断副图：确认式打点 + 会话事件日志累积全部历史点。
  void appendDisplayTrackFractalJudgment() {
    append(
      '【口径纠正】K(n-1)分型判断：确认式打点（成立当步，禁止整框回填）；'
      '步进/播放/一次性走完均逐 K 追加事件日志（x+fx 去重），绘制扫全部历史点，'
      '禁止只保留末态重算结果；换股/重载才清空。'
      '十字线 as-of 仅过滤 x>asOf；展示轨仍走 computeK0/K1CombineFrames'
      '（含 truncationCheck）；半透明空心；不回写结构。',
    );
  }

  /// 展示轨：动态 KN 当确认段画虚线；分型确认优先纠正/改实线；不回写。
  void appendDisplayTrackDynamicKnBuildingLines() {
    append(
      '【画线口径·改版v2+右组跨度首极值开口】KN/K0 构建中连线=动态KN几何 + 当下分型判断拆段：'
      '右组=分型第三元素 K0 跨度[rightX1,rightX2]全层同构'
      '（K0 确认@8→[8,8]；K1 判断@58→[55,58]）；'
      '判断刚成立开口：极点→右组内方向首极值；确认刚成立开口：右组=[x,x] 内首极值；'
      '禁止中组内扫价（如 44→47）；确认后延伸仍从确认极点扫 asOf。'
      '【补洞·无确认有判断】confirmPoles 空时仍消费 liveJudgments：'
      '首判断用中组极点起链画开口虚线（例 K1@26 TOP fx6-25|r25-26）；'
      '无判断才退化未冻虚拟单元。此前早退忽略判断导致有副图判断无主图虚线。',
    );
  }

  /// 种子框首段（口径 A）：删审判；首两单元不做包含；JUDGE/CONFIRM 虚实线；
  /// UNKNOWN 开口虚线（方案2·D2·S-b，全层同构）。
  void appendSeedBoxFirstSeg() {
    if (_seedBoxFirstLogged) return;
    _seedBoxFirstLogged = true;
    append(
      '【首段策略·种子框口径A】已删除 trial/审判/bootstrap。'
      '每层第一个 Kn=种子合并框：group0 单元素永不吸收第二根；'
      'n>0 确认前可随下层进行中单元 probe 动态刷新高低，首分型确认后冻结。'
      '第二 Kn 不与种子框做包含，只与后续 Kn 关系。'
      '【UNKNOWN开口·方案2·D2·S-b·全层同构】仅 group0：只虚线种子框、不画连线；'
      '有 group1 后 seed_leave_dir=离开种子方向（test_combine_range(g0,g1)，互含=+1）；'
      'begin=框内出发极值（升=框低/降=框高）；尾端从 seed_box_x2 外扫'
      '(seed_x2,asOf] 首次同向极值（buildingTailEndpoint）；'
      'JUDGE/CONFIRM 让位 ABC：JUDGE→A→B(/B→C)虚；CONFIRM→A→B实、B→C虚。'
      '例外：首两单元不做包含（全层同构字面例外，登记 README）。'
      '历史记录按钮与 lib/history/ 常驻不得删。',
    );
  }

  /// test 股票：前端可编辑 OHLC，落盘 custom.ohlc.csv，加载时直读（忽略周期聚合）。
  void appendTestCustomOhlc() {
    if (_testCustomOhlcLogged) return;
    _testCustomOhlcLogged = true;
    append(
      '【test 自定义OHLC】股票选 test 后可「编辑/加载自定义 OHLC」：'
      '表格录入时间+OHLC(+量) → 保存到 a_Data/test/custom.ohlc.csv；'
      '有 CSV 时 load_klines 优先直读（不做分笔/周期聚合，行即最终K线）；'
      '无 CSV 时回退原 test 分笔文件。仅改 K0 数据源，K1/Kn 流水线不变。'
      '默认 custom.ohlc.csv=100 根强复杂性样本（包含合并/一字线/种子离开长 UNKNOWN/'
      '暴力下杀截断雏形/中枢震荡/多层波浪），便于全层同构排查开口虚线与递归层。'
      '历史记录按钮与 lib/history/ 常驻不得删。',
    );
  }

  /// 运行时虚线摘要（内容变才追加；复制历史记录排查用）。
  void appendDisplayBuildingLinesRuntime({
    required int kn,
    required int asOf,
    required List<K1Bar> virtualUnits,
    required Set<int> frozenIdx,
    required List<DisplayBuildingLine> lines,
    List<FractalJudgmentEvent> liveJudgments = const [],
  }) {
    final jPart = liveJudgments
        .map((j) =>
            '${j.x}:${j.fx}(${j.fractalX1},${j.fractalX2}|r${j.rightX1}-${j.rightX2})')
        .join(',');
    final unitPart = virtualUnits
        .map((u) =>
            '#${u.idx}dir${u.dir}[${u.x1},${u.x2}]'
            '${frozenIdx.contains(u.idx) ? "冻" : "动"}')
        .join(',');
    final linePart = lines
        .map((l) =>
            '${l.begin.barIdx}→${l.end.barIdx}'
            '(${l.beginSrc}/${l.endSrc}'
            '${l.asSolid ? ",实" : ",虚"}'
            '${l.isOpenTip ? ",开" : ""})')
        .join(';');
    append(
      '【调试·动态KN虚线】kn=$kn asOf=$asOf '
      'liveJ=[$jPart] 虚拟=${virtualUnits.length} 冻=${frozenIdx.length} '
      '线=${lines.length} | 单元=[$unitPart] | 线=[$linePart]',
    );
  }

  String asText([List<MsgHistoryEntry>? source]) {
    final src = source ?? _rows;
    return src
        .map((e) => '[${_fmtTime(e.time)}] ${e.text}')
        .join('\n');
  }

  Future<bool> copyToClipboard({
    List<MsgHistoryEntry>? source,
    String okMsg = '历史记录已复制',
    BuildContext? context,
  }) async {
    final text = asText(source);
    if (text.trim().isEmpty) {
      _showSnack(context, '没有可复制的内容');
      return false;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (context != null && context.mounted) {
      _showSnack(context, okMsg);
    }
    return true;
  }

  Future<void> showDialog(BuildContext context, {String title = '历史记录'}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) {
        return _MsgHistorySheet(title: title);
      },
    );
  }

  static String _fmtTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  static void _showSnack(BuildContext? context, String msg) {
    if (context == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }
}

class MsgHistoryEntry {
  final DateTime time;
  final String text;

  const MsgHistoryEntry({required this.time, required this.text});
}

class _MsgHistorySheet extends StatefulWidget {
  const _MsgHistorySheet({required this.title});

  final String title;

  @override
  State<_MsgHistorySheet> createState() => _MsgHistorySheetState();
}

class _MsgHistorySheetState extends State<_MsgHistorySheet> {
  final _history = MsgHistory.instance;

  @override
  Widget build(BuildContext context) {
    final rows = _history.rows;
    final h = MediaQuery.sizeOf(context).height * 0.62;
    return SafeArea(
      child: SizedBox(
        height: h,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: rows.isEmpty
                        ? null
                        : () => _history.copyToClipboard(
                              context: context,
                              okMsg: '历史记录已复制',
                            ),
                    child: const Text('一键复制历史记录'),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() => _history.clear(reason: '用户手动清空'));
                    },
                    child: const Text('清空'),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: rows.isEmpty
                  ? const Center(child: Text('暂无历史记录'))
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: rows.length,
                      itemBuilder: (_, i) {
                        final e = rows[rows.length - 1 - i];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: SelectableText(
                            '[${MsgHistory._fmtTime(e.time)}] ${e.text}',
                            style: const TextStyle(fontSize: 12, height: 1.35),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
