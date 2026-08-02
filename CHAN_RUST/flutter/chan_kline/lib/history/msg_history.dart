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

  /// 种子框首段是否已记录（进程内去重）
  static bool _seedBoxFirstLogged = false;

  /// 第一条虚线 sit1/sit2 限制是否已记录
  static bool _seedFirstDashRulesLogged = false;

  /// 种子相对第二框截断是否已记录
  static bool _seedContainTruncLogged = false;

  /// test 自定义 OHLC 口径是否已记录（进程内去重）
  static bool _testCustomOhlcLogged = false;

  /// 工作区全屏 + tooltip 分隔线口径是否已记录
  static bool _desktopWorkAreaLogged = false;

  /// ZG/ZD 常见命名 + Kn一类BS
  static bool _buy1ZgZdLogged = false;

  /// Kn二类BS 口径（进程内去重）
  static bool _buy2Logged = false;
  /// Kn三类+BS 口径（进程内去重）
  static bool _buyNLogged = false;

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

  /// 构建中连线虚线尾端：判断极点=分型框极值（与确认同构），开口尖端=右组跨度内首极值（全层同构）。
  void appendBuildingDashTailFirstExtreme() {
    append(
      '【画线口径·判断极点修正】KN/K0 构建中虚线的「判断极点」已改为与确认同构：'
      '取该 Kn 分型合并框 [fractalX1,fractalX2] 内首次方向极值（TOP=首高，BOTTOM=首低），'
      '不再用 buildingTailEndpoint 从上一极点往 asOf 扫价。'
      '确认极点仍为分型框极值，两者取点公式一致。'
      '开口尖端（判断刚成立时的虚拟下一方向预览）：'
      '起点=判断极点，终点=右组 [rightX1,rightX2]（Flutter 侧 FractalJudgmentEvent 计算，Rust LevelSnap 不直接携带）'
      '内方向首极值（禁止扫进中组如 44→47）。'
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

  /// 副图十字 as-of：确认/极点距/截断与成交量/判断同构，仅过滤 x>asOf。
  void appendSubChartCrosshairAsOf() {
    append(
      '【副图十字 as-of】十字线激活时副图与主图同构：只画十字当下及之前结果；'
      '成交量/分型判断/分型确认/极点距/截断均按 segAsOf 过滤 x>asOf（右侧不画）；'
      '关闭十字线仍画会话末态全量；不重算确认序列、不回写结构。',
    );
  }

  /// 主图中枢十字 as-of：Rust 重算 bundle；与主图强制同源。
  void appendZSCrosshairAsOf() {
    append(
      '【主图十字 as-of】K(n)中枢：十字线开启时对 bars[idx<=asOf] '
      '调用 buildKlineCombineBundle 取 Rust zs_* 帧（缓存 as-of bundle）；'
      '主图/tooltip 均消费 JSON，Flutter 不做本地 find_zs；'
      'isSure：离开闭合=true 实线，末开放=false 虚线（受构建中虚线开关）；'
      '关闭十字线画会话末态 zs_k0_* / levels[].zs_*；全层同号、不回写、无未来。',
    );
  }

  /// 中枢确定/不确定虚实线（对齐动态Kn；进程内去重）。
  static bool _zsSureDashLogged = false;
  void appendZSSureDashFrames() {
    if (_zsSureDashLogged) return;
    _zsSureDashLogged = true;
    append(
      '【中枢虚实线·全层同构】确定态实线框、不确定态虚线框（受「构建中/未确认虚线」开关）。'
      '口径：与上一中枢虚框不重叠的离开Kn，仅当该Kn为确认态时，上一虚框→实线定型；'
      '动态Kn离开即使不重叠也不得定型（禁未来函数）。绘制跟 is_sure，不用 active_unit 一刀切全虚。'
      'Rust find_zs_with_confirmed(n_confirmed)；Flutter 主图/tooltip 消费 Rust zs_* JSON。',
    );
  }

  /// K0中枢命名纠偏 + 单段雏形虚框（进程内去重）。
  static bool _k0ZsRenameLogged = false;
  void appendK0ZsRenameAndPrototype() {
    if (_k0ZsRenameLogged) return;
    _k0ZsRenameLogged = true;
    append(
      '【口径变更】真·K0中枢=原生分钟K段（每根K一段，JSON zs_k0_*）；'
      'Kn中枢=Kn连线段（levels[].zs_*）。买卖点(BSP)已全删。',
    );
  }

  /// 中枢全层同构：单段即可成中枢（进程内去重）。
  static bool _zsSingleSeedIsoLogged = false;
  void appendZsSingleSeedIsomorphic() {
    if (_zsSingleSeedIsoLogged) return;
    _zsSingleSeedIsoLogged = true;
    append(
      '【中枢·全层同构·单段成枢】K0/K1/…/Kn 算法同构 find_zs：'
      '单段种子(isSure=false)→重叠延伸→不重叠离开闭合(isSure=true)；'
      '一字线仅 open=close 锚定 ZG=ZD（近一字/小振幅不塌缩）；'
      '无离开-返回、无九段升级、无≥3段种子门槛。'
      '段实体按层：K0=分钟K，K1=K0连线段…'
      '【展示轨】主图/tooltip 强制 Rust zs_* 同源；十字线 as-of=buildKlineCombineBundle 切片。'
      'Kn 中枢喂入=冻结段+进行中 active_unit（末开放 is_sure=false 虚框，闭合后实线）。',
    );
  }

  /// 删除跨段中枢；原生中枢统一；放弃 Auto（进程内去重）。
  static bool _zsSplitLogged = false;
  void appendZSSplitNormalOverSeg() {
    if (_zsSplitLogged) return;
    _zsSplitLogged = true;
    append(
      '【口径变更】删除跨段中枢(KuaDuan)与三类买卖点(BSP)全部逻辑；'
      '原生中枢统一为「K(n)连续中枢」（单套 zs_frames，无 Normal/OverSeg 双轨）；'
      '流水线每层输出 JSON：zs_frames；'
      '放弃 Auto；呈现=半透明 ZD/ZG 框；全层同构、无未来、不回写。',
    );
  }

  /// 主图层色统一：同层合并/连线/中枢同色（进程内去重）。
  static bool _mainLevelColorLogged = false;
  void appendMainLevelUnifiedColors() {
    if (_mainLevelColorLogged) return;
    _mainLevelColorLogged = true;
    append(
      '【主图层色·同层同色】主图指标（Kn合并/Kn连线/Kn中枢，含构建中虚线、种子框）'
      '按展示层共用一色：K0蓝(0x6366F1)、K1黄(0xF59E0B)、K2粉(0xEC4899)、'
      'K3翠绿/K4紫/K5青/K6橙；原始 Kn 蜡烛仍红绿涨跌；副图/买卖点色不变。'
      '已删除未使用的 forZSOverSeg 遗留配色。',
    );
  }

  /// 主图「Kn中枢」命名/层序 + 副图顶底色（进程内去重）。
  static bool _mainZsRenameOrderFxLogged = false;
  void appendMainZsRenameOrderAndFxColors() {
    if (_mainZsRenameOrderFxLogged) return;
    _mainZsRenameOrderFxLogged = true;
    append(
      '【主图·Kn中枢命名与层序·全层同构】展示名「Kn连续中枢」→「Kn中枢」；'
      '同层指标序=Kn→Kn合并→Kn中枢→Kn连线；Kn中枢框内斜线填充以区分合并框。'
      '【副图·顶底色自定义】分型确认/判断：底分型红、顶分型蓝；'
      '截断：向下截断(=底分型截断)红、顶分型截断蓝（另加橙描边）。',
    );
  }

  /// 展示轨：动态 KN 当确认段画虚线；分型确认优先纠正/改实线；不回写。
  void appendDisplayTrackDynamicKnBuildingLines() {
    append(
      '【画线口径·改版v2+右组跨度首极值开口】KN/K0 构建中连线=动态KN几何 + 当下分型判断拆段：'
      // 注：右组 [rightX1,rightX2] 由 Flutter 侧 FractalJudgmentEvent 根据 K0/K1 合并框计算得出（非 Rust LevelSnap 直接传入），
      // 各层合并采集（k0_combine_compute.dart / k1_combine_compute.dart）在写入 FractalJudgmentEvent 时均带齐此字段，
      // 故画线公式一层一套、各层共用，仍为全层同构。
      '右组=分型第三元素 K0 跨度[rightX1,rightX2]（Flutter 侧全层同构：K0 确认@8→[8,8]；K1 判断@58→[55,58]）；'
      '判断刚成立开口：极点→右组内方向首极值；'
      '确认开口（含刚成立当步）：一律从确认极点扫 (pole,asOf] 方向极值首次出现根'
      '（取消确认刚成立右组=[x,x] 特例，避免终点跳到确认本根；并列极值取先出现）；'
      '禁止中组内扫价（如 44→47）。'
      '【补洞·无确认有判断】confirmPoles 空时仍消费 liveJudgments：'
      '首判断用中组极点起链画开口虚线（例 K1@26 TOP fx6-25|r25-26）；'
      '无判断才退化未冻虚拟单元。此前早退忽略判断导致有副图判断无主图虚线。',
    );
  }

  /// 第一个分型合并框（种子框）逻辑（全层同构，常驻）。
  /// 引擎入口：engine.rs CombineEngine.seed_skip_first flag；LevelSnap.seed_* 快照字段。
  void appendSeedBoxFirstSeg() {
    if (_seedBoxFirstLogged) return;
    _seedBoxFirstLogged = true;
    append(
      '【种子框·第一个分型合并框·全层同构】每层第一个 Kn=种子合并框 group0：'
      'CombineEngine.seed_skip_first=true → 单元素永不吸收第二根；第二 Kn 强制自成 group1（首两单元不做包含，字面例外见 README）。'
      'n>0 确认前可随下层进行中单元 probe 动态刷新高低；首个 Kn 分型确认后 LevelSnap.seed_confirmed 冻结。'
      '画线阶段：UNKNOWN→开口虚线（见第一条虚线限制）；JUDGE→A→B(/B→C)虚；'
      'CONFIRM→A→B实(冻结段)、B→C虚。历史记录按钮与 lib/history/ 常驻不得删。',
    );
  }

  /// 第一条虚线（种子 UNKNOWN 开口）sit1/sit2 限制（全层同构，常驻）。
  void appendSeedFirstDashRules() {
    if (_seedFirstDashRulesLogged) return;
    _seedFirstDashRulesLogged = true;
    append(
      '【第一条虚线限制·全层同构】首分型确认/判断前：种子框 h1/l1 对照动态末组 hn/ln'
      '（n>0；动态末组=冻组合并+下层进行中 pending 的 probe 吸收/成组，与展示轨动态Kn合并同口径）：'
      'sit1(hn>h1且ln>l1)→seed_leave_dir=+1 画开口虚线；'
      'sit2(hn<h1且ln<l1)→seed_leave_dir=-1 画开口虚线；'
      'hn<=h1且ln>=l1（含全等）→leave_dir=0 不画；其它重叠亦不画。'
      '几何：begin=框内出发极值（升框低/降框高）；尾端从 seed_box_x2 外扫'
      '(seed_x2,asOf] 首次同向极值；JUDGE/CONFIRM 让位 ABC。'
      '【虚实线·全层同构】动态Kn/动态Kn合并/Kn分型判断→虚线；'
      '确认Kn/确认Kn合并/Kn分型确认→实线；优先级：确认>动态/判断。'
      '（曾误修截断首段端点已撤销，截断首段仍走常规 First。）'
      '历史记录按钮与 lib/history/ 常驻不得删。',
    );
  }

  /// 种子相对第二框包含截断（全层同构，常驻）。
  void appendSeedContainTruncation() {
    if (_seedContainTruncLogged) return;
    _seedContainTruncLogged = true;
    append(
      '【第一条虚线·截断门控·全层同构】仅「第一个Kn后→第一个Kn分型确认/判断前」：'
      'sit1/sit2 leave → 该窗口内不再触发截断；'
      '非 leave 且第二框严格包含种子 → 该窗口内截断至多一次；'
      '方向 dh/dl 同前；动态Kn截断→Kn分型判断(probe)；确认Kn截断→Kn分型确认(feed)。'
      '首个分型确认/判断之后的 TruncGuard 等保持原实现，不受本门控。'
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

  /// ZG/ZD common naming + Kn class-1 BS (dedupe in-process).
  void appendBuy1AndZgZdCommonNaming() {
    if (_buy1ZgZdLogged) return;
    _buy1ZgZdLogged = true;
    append(
      '【口径·ZG/ZD常见命名】Rust/Flutter 中枢字段互换为常见缠论命名：'
      'ZG=重叠上沿(=框 high)、ZD=重叠下沿(=框 low)；算法数值与框几何不变，仅名称对齐。'
      '【新增·Kn一类BS·全层同构】买：当前中枢框整体在上个下方（ZG_curr < ZD_prev）；'
      '卖：镜像（ZD_curr > ZG_prev）。框内成员按序标 1Ba…、1Sa…；'
      '同枢仅建框/严格新极值标一类（等高/更弱不再标一类，改归二类）；'
      '买侧高于或等于本枢框最低不标一类、卖侧低于或等于本枢框最高不标一类（全层同构；'
      '参照=本枢已见最低/最高，跳过时不抬高/压低参照——禁止与「上一成员」比）；'
      '更极值重置字母不回写旧标签；'
      '各层第一个Kn(segs下标0)不参与。Kn≥1 与动态中枢同构：喂入=冻段+active_unit（segments_with_optional_active / find_zs_with_confirmed）；动态伪段按 dir 锚定极点（跌低/涨高在 end）；打点 x=极值极点与段右端取 max（禁止回写到段起点）；'
      '若本 ZS 已有前序标签且点落在 active 伪段，x 钉在 begin_pole+1（首段身），不把旧点挪到新右端；'
      'Flutter：对齐 Kn分型判断=「K0步进颗粒度 + 动态Kn作判断元素」：会话追加不删旧；首次 x=stepIdx；'
      'Kn≥1 动态 active 本步仍成立则再追加本步 x（稳定键层|段|标签 + 颗粒度键含x；同 seg/label 可多 x）；'
      '【踩坑·2026-07-30】勿把「对齐分型判断」做成只用稳定键去重/只留发现点：'
      '002003 step27 Rust仍出1Sa、Flutter dedup_skip→副图尾柱无点、十字 sellAtAsOf=null；'
      '副图/十字只扫历史 x<=maxX；K0 无 active 仍用分钟K段。JSON：buy1_k0_frames/sell1_k0_frames、'
      'levels[].buy1_frames/sell1_frames；副图指标「Kn一类BS」与中枢同层同号'
      '（买点副图+1红、卖点-1绿）；无未来、不回写。步退按可见尾柱裁切。',
    );
  }

  /// Kn二类BS（与一类同框；方案A）
  void appendBuy2Class2Naming() {
    if (_buy2Logged) return;
    _buy2Logged = true;
    append(
      '【新增·Kn二类BS·全层同构·方案A】与一类同一资格中枢框（买下移/卖上移）；'
      '按成员序维护已见最低/最高：建框与严格新极值只标一类；'
      '买侧 low≥已见最低 → 2Ba/2Bb…；卖侧 high≤已见最高 → 2Sa…（镜像）；'
      '字母一类/二类各自独立；一类建框/新极值复位时二类字母同步重起（2Ba/2Sa）。'
      '同段互斥分区。'
      '喂入/打点x/active钉点/Flutter双键会话冻结与一类同构；'
      'JSON：buy2_k0_frames/sell2_k0_frames、levels[].buy2_frames/sell2_frames；'
      '副图「Kn二类BS」；K0颗粒度可多点；无未来、不回写。',
    );
  }

  /// Kn三类及以上BS（链升类；全层同构）
  void appendBuyNClass3PlusNaming() {
    if (_buyNLogged) return;
    _buyNLogged = true;
    append(
      '【新增·Kn三类+BS·全层同构】以一类/二类资格中枢为链起点；'
      '买：相邻框连续 zd_k>zg_{k-1} → 三类/四类…；卖镜像 zg_k<zd_{k-1}；'
      '中间环不满足则该起点链断开，后续新资格框可开新链。'
      '同框每个成员（跳过层首）按序 3Ba/3Bb… 字母只递增不复位。'
      '打点x/active钉点/Flutter双键会话冻结与一类同构；K0颗粒度同柱可多类叠标。'
      'JSON：buy_n_k0_frames/sell_n_k0_frames、levels[].buy_n_frames/sell_n_frames（含 cls）；'
      '副图分槽「Kn三类BS」…「Kn九类BS」（更高类动态扩）；'
      '全类副图 S 在上(+1)冷色、B 在下(-1)暖色，同族内按类分档。',
    );
  }

  /// Kn相邻比例 + Kn步进节奏副图（进程内去重）
  static bool _adjacentRatioRhythmAppearLogged = false;
  void appendAdjacentRatioAndStepRhythm() {
    if (_adjacentRatioRhythmAppearLogged) return;
    _adjacentRatioRhythmAppearLogged = true;
    append(
      '【Kn相邻比例·全层同构·动态·K0颗粒度】'
      '【口径】指标设计遵循动态计算（除非明确指示其它逻辑）：'
      '子线=主图连线出现链（冻段实线+展示轨虚线/种子），虚实一视同仁；'
      '按起点极点 beginX 出现时机排序，取末两根 ratio=|cur|/|prev|；'
      '不要求 isSure；每步按 K0 idx 写入；denom≤1e-12 跳过；默认不勾选。',
    );
    append(
      '【Kn步进节奏·副图·normal·K0颗粒度·0-0组】'
      '仅 normal；全层同构；子线=出现链虚实不论；'
      '组锚=父分型极值（底→极低升组/顶→极高降组）；命名从 0-0；'
      '子同向分型开窗逐K续写，子反向分型确认后停写（单点不连后）；'
      '父分型确认本组停、下组重置自确认步绘；不回写无未来；'
      '绘制：同父级(roundRef)同色，升暖降冷；K0 对齐点线，Δx≠1 不跨缺口续连；名在左侧；默认不勾选。',
    );
    append(
      '【踩坑·比例/节奏·2026-07-31】'
      '①显示层 displayKn→数据 level=kn+1；节奏父切组用 level+2 的分型 confirms，勿用父段 end_confirm；'
      '②比例子线须含展示轨虚线/种子，勿只读冻段；按 beginX 出现序勿按 endConfirmX；'
      '③节奏命名 0-0 起；关窗后不续写；key 含 groupId；同棒 bootstrap→子窗→父切组；'
      '④验收连续单步非跳末。详见 TASK_LOG / AGENTS.md。',
    );
  }

  /// 默认 K0=原生分笔一字线（进程内去重）
  static bool _tickK0NativeLogged = false;
  void appendTickK0NativePeriod() {
    if (_tickK0NativeLogged) return;
    _tickK0NativeLogged = true;
    append(
      '【K0·原生分笔·默认】period=tick：每行分笔=一根K0，O=H=L=C=成交价（一字线）；'
      '【合成秒】同分钟 n 笔均分到 60s（base+k*60000/n ms，n=1 即0），time_text 秒位随序递进，'
      'X 轴/十字时间到秒，不再整屏 :00。源文件仅 HH:MM（如集合竞价行无 B/S）。'
      '缠论合并/分型公式不变（吃 high/low），与同区间1m结构不可直接对比；'
      'x 锚点=K0下标（tick 下即分笔序）。聚合周期仍 ticks→1m→升周期，主图恢复蜡烛。'
      '可选：1/5/15/30/60m、2h/4h、1d/3d、1w、1/3/6/9/12mon、1/3/6y。'
      '【筹码】tick 按分笔序写入 chip_tick_bins 三分量：B→b 红、S→s 绿、无BS→w 灰；'
      '无 BS 不再默认当 B（normalize_native 保持 has_bs=false）；w 不再是 s+b 合计，total=s+b+w；'
      '禁止 OHLC 三角兜底。副图 K0 成交量按 tick_side 着色（B红/S绿/灰），非 K0/聚合周期仍涨红跌绿；'
      '筹码柱右对齐三段（右B红/中S绿/左灰），右上角 B/S/灰度 累计角标随十字 as-of 与步进末根变化；'
      '十字悬停时角标下方另起「当前」行，分色高亮该单根 B/S/灰 量（区别于累计）；'
      '【踩坑】标题条勿用「屏宽-140固定开孔+Expanded」——窗控约174px会 RIGHT OVERFLOW；'
      '应用 Expanded(IgnorePointer) 穿透 + 窄条 DragToMoveArea。',
    );
  }

  /// 切周期立即自动重载口径是否已记录（进程内去重）
  static bool _periodAutoReloadLogged = false;
  /// 周期切换行为：下拉选周期 → 立即按新周期自动重载（2026-08-01 修复一字线误读）。
  /// 踩坑：改周期若只 setState 不重载，图表会用「新周期蜡烛画法」重绘内存中仍为 tick 的数据
  /// （每根 O=H=L=C），全部显示成一字线，误判为聚合错误；Rust 聚合本身产出真 OHLC 蜡烛。
  void appendPeriodAutoReload() {
    if (_periodAutoReloadLogged) return;
    _periodAutoReloadLogged = true;
    append(
      '【周期切换·自动重载】下拉选周期立即调用 _loadKlines 按新周期拉数，无需手动加载。'
      '背景：改周期只改 _period 会令图表用新周期蜡烛画法重绘未重载的 tick 数据'
      '（O=H=L=C），整屏一字线；已改为选中即自动重载，并同步更新周期说明弹窗。'
      '聚合口径不变：仍 ticks→1m→升周期，主图恢复蜡烛。',
    );
  }

  /// 桌面窗体：铺满工作区不盖任务栏；十字线 tooltip 分隔线贴边框。
  void appendDesktopWorkAreaAndTooltipSep() {
    if (_desktopWorkAreaLogged) return;
    _desktopWorkAreaLogged = true;
    append(
      '【桌面窗体】启动/最大化按钮铺满当前屏工作区（screen_retriever.visibleSize），'
      '不覆盖任务栏；TitleBarStyle.hidden 下禁用原生 maximize（会盖任务栏）。'
      '【十字线 tooltip】==== / 。-。 分隔线超量重复后 ClipRect 裁切，贴齐左右边框。',
    );
  }

  /// 主/副图指标 UI：Kn中枢命名、层全选、Kn成交量归属、chip 单击关闭（进程内去重）。
  static bool _indicatorUiKnVolumeLogged = false;
  void appendIndicatorUiAndKnVolume() {
    if (_indicatorUiKnVolumeLogged) return;
    _indicatorUiKnVolumeLogged = true;
    append(
      '【主/副图指标 UI】主图选择名「Kn中枢」与 tooltip 对齐；'
      '主图中枢框/合并框只画框，取消框内「Kn中枢…」「顶/底」文字。'
      '选择栏默认叠加，取消「叠加」单选；最上新增「Kn指标」层全选'
      '（主图层内序=Kn/Kn合并/Kn中枢/Kn连线；副图=Kn成交量+分型确认/判断/极点距/截断）。'
      '左上角已选：同层 /、跨层 ※、自动换行不压字、单击关闭；'
      '副图读数跟在指标名后方；避让主图右上窗控。',
    );
    append(
      '【Kn成交量·全层同构】成交量按层为 K0/K1/…/Kn成交量；'
      'K0=原生 bars.volume；Kn(n>0)=按 LevelBundle 单元投影到 K0 槽。'
      '相邻 Kn 共享 end_pole(junction)：该 K0 量归已确认段；'
      '新动态 Kn 从 junction+1 起计，不占刚确认末根成交量；'
      '不回写 LevelUnitBar.volume（单元 OHLCV 总量语义保持）。',
    );
  }

  /// 左上角灰度开关 + Kn成交量进副图读数（进程内去重）。
  static bool _indicatorMuteToggleLogged = false;
  void appendIndicatorMuteToggleAndVolReadout() {
    if (_indicatorMuteToggleLogged) return;
    _indicatorMuteToggleLogged = true;
    append(
      '【指标左上角】单击名称=灰度关闭（不绘制，名称灰+删除线），再点打开；'
      '不从选择集移除；选择栏取消勾选才真正移除。开启态白字加粗提高对比度，'
      '灰度态 #6B7280 易区分；芯片静止透明度约 0.88。'
      '【副图读数】已选副图指标名称后方直接挂当前值（十字当步/否则末根）；'
      '取消副图右上角独立读数框。'
      '【主 tooltip】各层 OHLCV 预留 VOL 槽改为填 Kn成交量序列（K0=原生，Kn=累加）；'
      '不在 tooltip 底部再追加 Kn成交量行。',
    );
  }

  /// 动态 Kn 成交量 = 下层增量步进累加（进程内去重）。
  static bool _knVolCumStepLogged = false;
  void appendKnVolumeCumulativeStep() {
    if (_knVolCumStepLogged) return;
    _knVolCumStepLogged = true;
    append(
      '【Kn成交量·累加步进】K0=原生 bars.volume；'
      'Kn：确认态终点落位 end_pole(x2)，confirmX 为确认步；'
      '确认前画面可画到 confirmX-1（可越过极点）；确认步起新动态画面。'
      '共享 K0=上一单元 end_pole(x2)：归已确认段，动态累加从 x2+1 起（不再纳入）；'
      '画面从上一 confirmX 起写，避免确认前未来切段；全层同构。不回写 unit.volume。',
    );
  }

  /// Kn笔数真实口径：Rust 分笔第4列笔数直加，替代 bins 数组长度（进程内去重）。
  /// 踩坑：bins['b'/'s'/'w'] 每个价位恒各 push 1 元素（缺方向补 0），长度≠笔数——
  /// tick 恒 3、日线=3×价位数（202→606）。真实笔数在分笔第 4 列（`09:30 35.10 60 10 B` 的 10）。
  static bool _knTickCountRealLogged = false;
  void appendKnTickCountRealTicks() {
    if (_knTickCountRealLogged) return;
    _knTickCountRealLogged = true;
    append(
      '【Kn笔数·真实笔数】Rust 分笔解析第 4 列笔数（HH:MM 价格 量 笔数 [B/S]；'
      '无列/非数字按 1 笔；显式 0 保留 0），tick/Day3/普通周期三路径均写 bar.metrics：'
      'tick_count（总，含灰度 w）、buy_tick_count（B）、sell_tick_count（S）；'
      '非法行（价格/量）不计，与 from_side_rows 同口径。'
      'Flutter K0 笔数优先读 metrics.tick_count / buy_tick_count，旧数据回退 bins 长度、'
      '再回退 tick_side；Kn=下层增量累加步进与成交量同构。'
      '【踩坑】勿用 bins 数组长度当笔数（每价位三数组各 push 1，长度恒=3×价位数）；'
      '笔数 metrics 键存在即用（可为 0，勿用 >0 判断），无键才回退。'
      'crosshairSubRows 新增 tickCount 分支 → 副图读数/十字 tooltip 显示真实笔数。',
    );
  }

  /// 分笔第4列显式 0 ≠ 缺列默认 1（进程内去重）。
  static bool _tickCountZeroLiteralLogged = false;
  void appendTickCountZeroLiteral() {
    if (_tickCountZeroLiteralLogged) return;
    _tickCountZeroLiteralLogged = true;
    append(
      '【Kn笔数·显式0·2026-08-02】分笔第4列写 0 时 ticks=0（副图/笔数分布全无柱）；'
      '仅无笔数列或第4列为 B/S 时默认 1。勿把 0 当成非法再默认成 1。'
      '须重编 chan_ffi.dll 后冷启。',
    );
  }

  /// 启动默认勾选「K0指标」层全选（进程内去重；配置易混写入历史便于复制排查）。
  static bool _defaultIndicatorsK0Logged = false;
  void appendDefaultIndicatorsK0() {
    if (_defaultIndicatorsK0Logged) return;
    _defaultIndicatorsK0Logged = true;
    append(
      '【默认指标】主/副图启动默认勾选「K0指标」层全选，'
      '与选择栏最上「Kn指标」同口径：'
      '主图=K0/K0合并/K0中枢/K0连线（筹码迁设置·仅K0，不在指标栏）；'
      '副图=K0成交量+分型确认/判断/极点距/截断+一类/二类BS+K0相邻比例/步进节奏'
      '（截断随截断开关 prune）。'
      '非 K1 层；加载后仅 prune 超出 catalog 的项，不改层。',
    );
  }

  /// 筹码分布：迁设置控制·仅K0 + 分笔 bins + 十字 as-of 截断（进程内去重）。
  static bool _chipDistributionLogged = false;
  void appendChipDistribution() {
    if (_chipDistributionLogged) return;
    _chipDistributionLogged = true;
    append(
      '【筹码分布·迁设置·仅K0】筹码迁出主图指标（目录/层全选/默认勾选均移除），'
      '改由设置面板总开关控制，仅保留 K0 分支；'
      'cutoff=当前步进末根 / 十字 as-of 所在 K0（不再映射 Kn 层）。'
      '主图右侧水平柱（左绿S/右红B），峰延长线横穿主图。'
      '数据：离线分笔注入 chip_tick_bins（p/s/b/w）；'
      'tick/一字线无 bins 时收盘价单点落量（禁三角）；其余无 bins 才 OHLC 三角兜底。'
      '计算：Rust chan_chip_profile（cutoff_x 含）。'
      '性能：Flutter 前缀索引（步进增量/十字 as-of 秒查）+ 底图/筹码/十字三层 RepaintBoundary；'
      '大序列 Isolate 后台预热前缀（跳末/加载），计算口径不变。'
      '逐K当下性：只累加已喂入 bars；十字 as-of 回滚到该日累积，不回写历史桶。'
      '配置：chipEnabled/bucketStep/stretch/peakLine；落盘 .chan_chip_config.json。'
      '【优化】开启筹码分布时主图 Y 轴价签与十字价格标签改左侧，避免被右侧筹码挡住。',
    );
  }

  /// 筹码迁设置（仅K0）+ 副图比例/节奏进 Kn指标（进程内去重）。
  static bool _chipMainRatioLevelLogged = false;
  void appendChipToMainAndRatioInSubLevel() {
    if (_chipMainRatioLevelLogged) return;
    _chipMainRatioLevelLogged = true;
    append(
      '【指标归属·筹码迁设置】Kn筹码分布从主图指标迁出，不再进「Kn指标」层全选，'
      '只保留 K0 分支、由设置面板「筹码分布」总开关控制（K1/…/Kn 筹码分支移除）。'
      '副图「Kn相邻比例」「Kn步进节奏」仍纳入「Kn指标」层全选与默认 K0 全选；'
      '副图 catalog 按显示层交错排列。',
    );
  }

  /// 十字 tooltip 标签格式化（进程内去重）：K{n}[No.]/…序/…组No. → … idx；合并取 GG/DD + MG/MD。
  static bool _tooltipFormatLogged = false;
  void appendTooltipFormatting() {
    if (_tooltipFormatLogged) return;
    _tooltipFormatLogged = true;
    append(
      '【tooltip 格式化·全层同构】十字线各层行标签统一：'
      'K{n}[No.]→「K{n} idx」、K{n}合并K{n}序→「K{n}合并K{n} idx」、K{n}合并组No.→「K{n}合并 idx」；'
      '「K{n}合并」取值仿照中枢改显 GG/DD（逐K当下区间极值，原 H/L），并保留原 H/L 改名为 MG/MD'
      '（M=merge，取该合并框框体高低点，as-of 框体与主图框同源、无未来函数；未闭合构建中与 GG/DD 不同，'
      '无框体时回退同值）；'
      '中枢价格行去掉「价格」后缀只留「K{n}中枢」，'
      '「K{n}中枢Kn序」中 Kn 换为对应层级（K0中枢K0 idx / K1中枢K1 idx），'
      '「K{n}中枢组No.」→「K{n}中枢 idx」；Kn 块行序与 K0 块同构：合并(GG/DD/MG/MD)→合并K序→合并idx→分型确认/判断。',
    );
  }

  /// 合并 GG/DD 口径修正（进程内去重）：GG/DD=组内原始K高低极值，MG/MD=合并框框体高低点。
  static bool _mergeRangeExtremeLogged = false;
  void appendMergeRangeExtreme() {
    if (_mergeRangeExtremeLogged) return;
    _mergeRangeExtremeLogged = true;
    append(
      '【K{n}合并 GG/DD 口径·2026-08-01】GG/DD 由「合并框高低点」修正为「组内原始区间极值」：'
      '在悬停合并组 x1..x2 内取各原始K的 max(high)/min(low)，逐K当下、无未来函数；'
      'K0 用原始K高低跑（如向上包含时 idx=2 显示 DD=11.68=组内 idx1 的 low，而非框体低点 11.70）；'
      'Kn 用当步单元高低跑、combineX1 变则切组重算，与 K0 全层同构。'
      'MG/MD 仍为该合并框框体高低点（构建中虚线框悬停框内中段时与 GG/DD 不同，闭合时同值）。'
      '踩坑：勿把「合并」的 GG/DD 当框体取——框体高低点是 MG/MD 的语义。',
    );
  }

  /// tooltip VOL/笔数 B/S/G + 应显尽显槽位（进程内去重）。
  static bool _tooltipVolBsgLogged = false;
  void appendTooltipVolBsgAndSlots() {
    if (_tooltipVolBsgLogged) return;
    _tooltipVolBsgLogged = true;
    append(
      '【tooltip VOL/笔数 B/S/G·应显尽显·2026-08-02】'
      '各层 OHLCV 的 VOL 改为 B/S/G（G=gray/灰度）；Kn笔数同行式 B/S/G，与副图同源累加。'
      '十字信息不按主/副图勾选过滤，按层（===）与类别（-。-。-。-。-）固定槽位应显尽显；'
      '类别块之后若是下一层级则只保留 ===，不挂类别尾分隔。'
      '层内序：价量笔→合并/分型→中枢→极点距/截断/BS/比例/节奏。',
    );
  }

  /// tooltip 成交量独立行 + 比例/节奏命名与多节奏动态行（进程内去重）。
  static bool _tooltipVolIndepLogged = false;
  void appendTooltipVolIndepAndRhythm() {
    if (_tooltipVolIndepLogged) return;
    _tooltipVolIndepLogged = true;
    append(
      '【tooltip 成交量独立·比例/节奏·2026-08-02】'
      'Kn OHLC 与成交量拆行：Kn=O/H/L/C，Kn成交量=B/S/G；有数值一律【】。'
      '命名：Kn相邻比例→Kn比例、Kn步进节奏→Kn节奏；X类BS 独立类别；比例+节奏独立类别。'
      '节奏颗粒度 K0，同棒可多值：动态行名「K{n}节奏{label}」如 K0节奏0-0：【价】；无点时占位 K{n}节奏【0】。'
      '层内序：价量笔→合并/分型→中枢→极点距/截断→X类BS→比例/节奏。',
    );
  }

  /// K0 筹码峰/笔数峰 tooltip + 左侧笔数分布（进程内去重）。
  static bool _chipTickPeakLogged = false;
  void appendChipTickPeaksAndTickDist() {
    if (_chipTickPeakLogged) return;
    _chipTickPeakLogged = true;
    append(
      '【K0筹码峰/笔数峰·笔数分布·2026-08-02】'
      'tooltip 仅 K0 增加独立类别：K0筹码峰、K0笔数峰；动态名 -/＋n：'
      '-1=当前低价之下最近峰，+2=高价之上且中间还有一峰；落在高低之间无 -/＋。'
      '格式：K0筹码峰-1：【价】/B：【】S：【】G：【】（笔数峰同）。'
      '笔数分布：主图左侧、与筹码同构（chip_tick_count_bins）；价签画在分布右侧；'
      '桶宽与筹码共用。',
    );
  }

  /// K0 分型确认/极点距/截断语义统一（进程内去重；防误读 level==1 为 K1）。
  static bool _k0FxSrcUnifiedLogged = false;
  void appendK0FractalSourceUnified() {
    if (_k0FxSrcUnifiedLogged) return;
    _k0FxSrcUnifiedLogged = true;
    append(
      '【K0分型确认/极点距/截断·语义统一·2026-08-02】'
      '显示名 K0分型确认 / K0分型极点距 / K0截断 一律读同一宗：'
      'k0_confirm + barFeatures.fractalPeakDist（Rust enrich 自 k0_confirm）。'
      '说明：pipeline levels[level==1].confirms 的「输入」是原始 K0，与 k0_confirm 数值同源；'
      'level==1 的 units/segments 才是 K1（K0连线）。'
      '禁止再优先走 LevelBundle(level==1) 再回退 k0——双轨易被误判为「读的是 K1 层」。'
      '副图/tooltip/crosshairSubRows 同构：kn==1→k0/feat；kn≥2→level_confirms[kn]。'
      '旧测试注释「K0分型确认=K1端点确认」已废止。',
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
