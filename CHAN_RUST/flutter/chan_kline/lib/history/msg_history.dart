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

  /// 方案B层号改口径是否已记录
  static bool _planBLayerRemapLogged = false;

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

  /// 智能体长期记忆（任务演示 / 前后对比）
  static bool _agentLongTermMemoryLogged = false;

  /// 工作区全屏 + tooltip 分隔线口径是否已记录
  static bool _desktopWorkAreaLogged = false;

  /// ZG/ZD 常见命名 + Kn一类BS
  static bool _buy1ZgZdLogged = false;

  /// Kn二类BS 口径（进程内去重）
  static bool _buy2Logged = false;
  /// Kn三类+BS 口径（进程内去重）
  static bool _buyNLogged = false;
  /// 全类 BSP 在线对错
  static bool _bsVerdictLogged = false;

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

  /// 方案B：Flutter 彻底改层号（Rust structure 0 起编；连线族 kn==displayKn）。
  void appendPlanBLayerRemap() {
    if (_planBLayerRemapLogged) return;
    _planBLayerRemapLogged = true;
    append(
      '【口径·方案B层号】Rust structure 0 起编：levels[].level==0=K0连线；'
      '中枢/BS 帧 frame.level=structure+1（显示中枢号）。'
      '连线族（line/combine/kn/三型/四型/趋势线/分型副图/截断/比例/节奏/斜率）'
      'catalog kn==displayKn，取数 LevelBundle.level==kn（去掉 displayKn+1 / 绘制 kn-1）。'
      '中枢/Math/volume/BS/背驰：K0=原生 k0；K1+ 取 structure level==kn-1。'
      'collect*ByKn：out[0]=k0，pipeline 写 out[lv.level+1]；'
      'levelsWithFrozen*Bs history 键 display=lv.level+1。'
      'chartMaxKn=structureMax+1（无 levels 有 k0Lines→1；全空→0）。'
      'asOfLevel* 按 lv.level==level 查找（允许 0）。勿再改回旧 1 起编。',
    );
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
      '对象=尚未确认的分型（非新芽/新分型）；与 Kn分型确认、Kn中枢判断/确认同一精神。'
      '步进/播放/一次性走完均逐 K 追加事件日志（x+fx 去重），绘制扫全部历史点，'
      '禁止只保留末态重算结果；换股/重载才清空。'
      '十字线 as-of 仅过滤 x>asOf；展示轨仍走 computeK0/K1CombineFrames'
      '（含 truncationCheck）；半透明空心；不回写结构。',
    );
  }

  /// Kn中枢判断/确认副图（全层无差别同构；进程内去重）。
  static bool _knZsJudgeConfirmLoggedV11 = false;
  void appendKnZsJudgeConfirm() {
    if (_knZsJudgeConfirmLoggedV11) return;
    _knZsJudgeConfirmLoggedV11 = true;
    append(
      '【Kn中枢判断/确认·副图·v11·未确认共点】'
      '【口径】对象=尚未确认的中枢，不是新芽/新中枢；与分型判断/确认同一精神。'
      '全层同一 merge，无 K0 特例。'
      'K0 无动态 Kn：离开常与定型同拍 → 判断与确认同 x/x1 → 副图标记重叠（预期）。'
      '判断：①离开窗对尚未确认上个框可逐K；②本步刚确认的框同拍打判断（与确认重叠）；'
      '③禁止单开放给新芽首次可判。'
      '确认：is_sure 首次。色：空间抬高红下移绿。不回写；十字 asOf 截断。'
      '【经验】勿 first.dir 配色；勿同拍打新芽（idx=7 异框）；'
      '勿套分型新芽首次可判；确认同拍须补判断（否则 K0 判断易全0）。',
    );
  }

  /// 分型/中枢判断·确认对象口径（与 AGENTS 常驻条同步；进程内去重）。
  static bool _fxZsTargetUnconfirmedLogged = false;
  void appendFxZsJudgeConfirmTarget() {
    if (_fxZsTargetUnconfirmedLogged) return;
    _fxZsTargetUnconfirmedLogged = true;
    append(
      '【口径纠正·分型/中枢判断确认对象】'
      'Kn分型判断、Kn分型确认、Kn中枢判断、Kn中枢确认：'
      '对象=尚未确认的分型/中枢；禁止当成对新芽/新分型/新中枢的判断或确认。'
      'K0 中枢判断与确认副图标记应重叠（无动态Kn、确认同拍共点）。',
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

  /// 智能体长期记忆：Task Log + test 演示 + 同页前后对比（常驻）。
  void appendAgentLongTermMemory() {
    if (_agentLongTermMemoryLogged) return;
    _agentLongTermMemoryLogged = true;
    append(
      '【智能体长期记忆·2026-08-15】全智能体（Cursor/OpenCode/Claude Code/WorkBuddy 等）'
      '任务完成后必须写 task-log.md；修改类任务须提供可演示验收：'
      '优先默认股票002003，否则在 a_Data/test/demos/{task_id}/ 建 manifest+before/after；'
      '股票选 test →「任务演示/前后对比」同页上=原本实现、下=本次实现。'
      '详见仓库 AGENT_LONG_TERM_MEMORY.md。'
      '历史记录按钮与 lib/history/ 常驻不得删。',
    );
  }

  static bool _devDemoPhaseLogged = false;
  static bool _agentConfirmGateLogged = false;

  /// 开发演示阶段：启动自动加载最新任务 + 点击下一步步进（常驻）。
  void appendDevelopmentDemoPhaseLaunch() {
    if (_devDemoPhaseLogged) return;
    _devDemoPhaseLogged = true;
    append(
      '【开发演示阶段·2026-08-15】默认开启：启动 exe 自动加载 demos 最新任务；'
      '主图底部叠层左=原本/右=本次，点「下一步」步进；可自动播放。'
      '设置「开发演示阶段」关=不再自动加载。落盘 .chan_task_demo_settings.json。'
      '历史记录按钮与 lib/history/ 常驻不得删。',
    );
  }

  /// 确认执行门禁 + 演示白话 + 接任务必读（常驻）。
  void appendAgentConfirmExecuteGate() {
    if (_agentConfirmGateLogged) return;
    _agentConfirmGateLogged = true;
    append(
      '【智能体门禁·2026-08-15】接任务先读 AGENT_LONG_TERM_MEMORY.md §0。'
      '用户未说「确认执行」禁止改 app 关键逻辑（缠论内核/步进冻结/主图语义）；'
      '须先文字提修改方案。演示 before/after/步进说明用白话，少贴代码名。'
      'CLAUDE.md / OPENCODE.md / .cursor/rules 均指向同一规范。'
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
      'V2.1：建框/严格新极值→1Ba/1Sa并更新参照；等高/等低→1Bb/1Bc…/1Sb…（不产生二类）；'
      '严格更高低点/更低高点→二类 2Ba…/2Sa…（一类跳过）；'
      '禁止同价 1B*+2B* 双标；'
      '参照=本枢已见最低/最高，跳过时不抬高/压低参照——禁止与「上一成员」比；'
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
      '【新增·Kn二类BS·全层同构·V2.1】与一类同一资格中枢框（买下移/卖上移）；'
      '按成员序维护已见最低/最高：建框/严格新极值/等高确认只标一类（1Ba/b/c…）；'
      '买侧仅 strict higher low → 2Ba/2Bb…；卖侧仅 strict lower high → 2Sa…（镜像）；'
      '等高/等低不产生二类（消除同价双标）。'
      '字母一类/二类各自独立；一类建框/新极值复位时二类字母同步重起（2Ba/2Sa）。'
      '同段互斥分区。'
      '喂入/打点x/active钉点/Flutter双键会话冻结与一类同构；'
      'JSON：buy2_k0_frames/sell2_k0_frames、levels[].buy2_frames/sell2_frames；'
      '副图「Kn二类BS」；K0颗粒度可多点；无未来、不回写。',
    );
  }

  static bool _pipelineSessionLogged = false;

  /// Phase 1.5：真实逐K 走 PipelineHandle（Rust 持 PipelineState）
  void appendPipelineStateSession() {
    if (_pipelineSessionLogged) return;
    _pipelineSessionLogged = true;
    append(
      '【Phase1.5·PipelineSession】图表会话=一个 Rust PipelineState；'
      'Flutter 只存 handle + presentation cache，不存核心判定 state。'
      '步进前进：首包 FFI chan_pipeline_append（Full Snapshot），'
      '其后 chan_pipeline_append_delta + mergeDelta（历史 bar_features 只追加，'
      '结构字段当步全量替换，不做字段级 patch）；'
      '失败回退 chan_pipeline_snapshot Full。'
      '步退/复位/换股/换周期/截断开关：reset+replay 或 dispose 后重建；'
      '关闭页面 dispose→chan_pipeline_free。'
      '黄金对照仍保留 chan_kline_combine_frames/run_pipeline；'
      '十字 asOf 仍走无状态短前缀 Full。'
      '算法/mark_x/discoveryX/V2.1 BS/History/Lookup 填表算法不变；'
      'Lookup 由 PresentationCache 增量维护，Painter 复用同一份。须重编 chan_ffi.dll。',
    );
  }

  static bool _incrementalLookupLogged = false;

  /// Phase 2B-3A：PresentationCache 增量 Lookup（禁全表 BarFeatureLookup.build）
  void appendIncrementalLookup() {
    if (_incrementalLookupLogged) return;
    _incrementalLookupLogged = true;
    append(
      '【Phase2B-3A·增量Lookup】步进不再全历史 BarFeatureLookup.build；'
      'PresentationCache.syncLookup：首包/回退一次 Full 种仓，热路径 applyStep 只写脏区间。'
      '永久冻结=旧 bar_features/History/Math冻格；只追加=byIdx[step]/新事件；'
      '当步可替换=末合并框/未确认中枢/当步 confirm；'
      'asOf=结构短前缀 Full + 冻格 x<=asOf，三型只算 asOf 柱。'
      'Full Lookup.build 保留为黄金参考。Painter/十字/chip/ML 复用同一份增量 Lookup。'
      '不改 Rust/Delta/算法/History/asOf/mark_x/V2.1 BS。',
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

  /// 全类 BSP 在线对错（独立 verdict；不回写 BSP）
  void appendBsOnlineVerdict() {
    if (_bsVerdictLogged) return;
    _bsVerdictLogged = true;
    append(
      '【新增·全类BSP在线对错·全层同构】覆盖当前全部类别 1B…nB / 1S…nS（类号从 label/cls 解析，不写死1/2/3）。'
      'Rust bs_eval 是唯一评判源：judge_level 对 K0…KN 同一入口。'
      'BSP 永久事件不改 x/price/seg/label；verdict 独立 Pending→Correct|Wrong 后冻结。'
      '对错=BSP之后第一个明确顺向确认或反向证伪事件（不要求必须等新中枢定型）。'
      '全类事件：非本框成员段相对本框 ZG/ZD 离开（买升破ZG=对、跌破ZD=错；卖镜像）；'
      '后续已定型中枢 zs_above_prev/zs_below_prev 仍是事件之一。'
      '一类/二类另继承同框严格新极值复位；三类+全员打点不套极值失败，但反向离开仍立即 Wrong。'
      '同x同时命中成功/失败：成功优先；不同x取最早。无未来：只使用 asof 已见结构；verdict_x≥bsp_x。'
      'JSON：bs_verdict_k0_frames、levels[].bs_verdict_frames。'
      '旧 ml_bsp_sample.isCorrect 仍是展望窗离线 α，不是在线 verdict。'
      'Flutter 只接收/冻结/asOf 过滤；设置「BSP对错叠加X」：错标叠加X，对的不叠加。'
      '强制验收：002003 1min K0 idx=12 → 4Sa.invalid_x=17（leave_above_zg）、1Ba.invalid_x=14（same_zs_new_extreme）。'
      '须重编 chan_ffi.dll；冷启动连续单步验收。',
    );
  }

  /// Kn相邻比例 + Kn步进节奏（进程内去重；节奏现主图，见 appendStepRhythmToMainAndTipCats）
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
      '【Kn步进节奏·主图价轴·normal·K0颗粒度·0-0组】'
      '仅 normal；全层同构；子线=出现链虚实不论；'
      '组锚=父分型极值（底→极低升组/顶→极高降组）；命名从 0-0；'
      '子同向分型开窗逐K实时算；子反向关窗后持上个 x-x 原值续写（升：顶关→底确认前；降镜像）；'
      '再开窗恢复实时；父分型确认切组并清空持值；不回写无未来；'
      '绘制：value=节奏投影价挂主图价轴；同父级(roundRef)同色，升暖降冷；'
      'K0 对齐点线，Δx≠1 不跨缺口续连；名在左侧；进主图Kn指标、默认静音。',
    );
    append(
      '【踩坑·比例/节奏·2026-07-31 / 持值2026-08-09】'
      '①方案B：显示层 displayKn→数据 LevelBundle.level==displayKn；节奏父切组用 displayKn+1 的分型 confirms，勿用父段 end_confirm；'
      '②比例子线须含展示轨虚线/种子，勿只读冻段；按 beginX 出现序勿按 endConfirmX；'
      '③节奏命名 0-0 起；关窗持同 key/同 value（例分笔 K1：77–114 续上个 0-0）；切组清 holdLines；'
      '④验收连续单步非跳末。详见 TASK_LOG / AGENTS.md。',
    );
  }

  /// Kn节奏关窗持值（进程内去重；2026-08-09）
  static bool _stepRhythmHoldLogged = false;
  void appendStepRhythmHoldBeforeChildReopen() {
    if (_stepRhythmHoldLogged) return;
    _stepRhythmHoldLogged = true;
    append(
      '【口径·2026-08-09·Kn节奏关窗持值·全层同构】'
      '升组：子顶关窗后、子底确认前，继续使用上个 x-x（同 key/同 value 逐K写入历史）；'
      '其它 x-x 同理；降组镜像。下一子同向分型开窗恢复实时；父分型切组清空持值。'
      '锚点验收：默认分笔·K1节奏·K0 77–114 续上个 0-0。'
      '主图/tooltip 共读会话历史（禁止只画不写）。'
      '验收：设置「复制调试信息」→T1持值·T2 tip同源。',
    );
  }

  /// tip三类分桶 + Kn节奏副→主（进程内去重；2026-08-08）
  static bool _stepRhythmMainTipCatsLogged = false;
  void appendStepRhythmToMainAndTipCats() {
    if (_stepRhythmMainTipCatsLogged) return;
    _stepRhythmMainTipCatsLogged = true;
    append(
      '【口径·2026-08-08·tip三类+节奏迁主图】'
      '十字 tip 层内拆三类（-。-分隔）：①Kn背驰_*；②Kn比例+Kn节奏*；'
      '③其它指标（均线/通道/斜率/三型四型/趋势线/MACD/布林/RSI/KDJ/Demark）。'
      'Kn节奏：删除 SubIndicatorKind.stepRhythm；改 MainIndicatorKind.stepRhythm；'
      '进主图「Kn指标」层全选（连线同号 0..maxKn-1）、默认静音；'
      '绘制挂价轴（value=节奏投影价）；副图 catalog/绘制/crosshairSubRows 已清干净。'
      '验收：设置「复制调试信息」→T1/T2。',
    );
  }

  /// Kn连线斜率副图（进程内去重）
  static bool _knLineSlopeLogged = false;
  void appendKnLineSlope() {
    if (_knLineSlopeLogged) return;
    _knLineSlopeLogged = true;
    append(
      '【Kn连线斜率·全层同构·动态·K0颗粒度】'
      '显示名 K{n}连线斜率；映射 displayKn→LevelBundle.level==displayKn（方案B；与比例/节奏/主图 Kn连线同号）。'
      '子线复用比例出现链（冻段实线+展示轨虚线/种子），虚实不论，按 beginX 出现序取末根；'
      'slope=(endVal-beginVal)/(endX-beginX)，endX=子线终点极点/开口 x；|dx|<1 或尚无子线不写点（tip【0】）。'
      '颗粒度 K0：每步 displayX=stepIdx 覆盖写入，不回写旧 x；虚线延伸步 slope 随终点变（当下性）。'
      '副图折线+0 轴虚线；升/降点色区分；十字 tip 固定槽位「K{n}连线斜率」。'
      '默认勾选：进 catalog +「Kn指标」层全选 + 启动默认 K0（与比例/节奏同口径）。纯 Flutter，不改 Rust。',
    );
  }

  /// 主图 Kn三型平移线 / Kn四型对线（进程内去重）
  static bool _knFxExtendLinesLogged = false;
  void appendKnFxExtendLines() {
    if (_knFxExtendLinesLogged) return;
    _knFxExtendLinesLogged = true;
    append(
      '【Kn三型平移线 / Kn四型对线·主图·全层同构·v1】'
      '显示名 K{n}三型平移线、K{n}四型对线；内部 kn==displayKn（方案B）；类别「延伸」。'
      '分型源仅已确认：K0=k0Confirms；Kn≥1→levels[level==displayKn].confirms；极点同连线 resolvePole/poleBarPrice。'
      '确认序滑动窗：三型窗长3（两同+一异→过异型向右）、四型窗长4（两顶线+两底线弦+向右）；|dx|<1 跳过。'
      '呈现：无十字只画最新合格窗；开十字只画焦点近邻窗（落窗优先，否则距区间最近）；'
      'tooltip 固定槽「K{n}三型平移线」「K{n}四型对线」=延长线落到该根K0的价格(四型分顶/底)，与主图筛选同口径。'
      '十字 asOf：只认 asOfBundle 的 confirms/levels（失败空，禁末态）；线型=层色构建虚线；'
      '射线右端截到 asOf 柱心（不向未来画到视口右缘）。'
      '默认勾选：进 catalog +「Kn指标」层全选 + 启动默认 K0。纯 Flutter，不改 Rust。',
    );
  }

  /// 主图 Kn趋势线（进程内去重）
  static bool _knTrendLineLogged = false;
  void appendKnTrendLine() {
    if (_knTrendLineLogged) return;
    _knTrendLineLogged = true;
    append(
      '【Kn趋势线·主图·子线层同号·v1】'
      '显示名 K{n}趋势线；内部 kn==displayKn（方案B）；类别「延伸」；移植旧 Math/TrendLine.py。'
      '映射：子线=levels[level==displayKn]，父段=levels[level==displayKn+1]（含 active）；K0 父=K1连线。'
      '父段内子线≥3：隔笔取样→峰值斜率→点到线距离和最小；INSIDE=支撑、OUTSIDE=压力。'
      '例外：依赖父层，最高层不作显示名；maxKn<2 目录仍挂 K0 占位（计算空）。'
      '呈现对齐三型/四型：无十字最新父段组；十字近邻组；父段弦+向右外推；层色构建虚线；'
      '十字 asOf 时射线右端截到 asOf（与蜡烛/均线同构）。'
      'tooltip「K{n}趋势线」=撑/压延长线落到该根K0价格；十字 asOf 只认 asOfBundle（禁末态）。'
      '默认：进 catalog +「Kn指标」层全选 + 启动默认 K0。纯 Flutter，不改 Rust。',
    );
  }

  /// 主图 Kn均线 / Kn通道（进程内去重）
  static bool _knTrendModelLogged = false;
  void appendKnTrendModel() {
    if (_knTrendModelLogged) return;
    _knTrendModelLogged = true;
    append(
      '【Kn均线/Kn通道·主图·全层同构·v2·当下冻结】'
      '显示名 K{n}均线、K{n}通道；kn 同中枢（0→K0）；类别「均线」；移植旧 Math/TrendModel.py。'
      '输入：K0=bars.close；Kn≥1=levels[level==n].unitBars(+active).close；滑窗 MEAN/MAX/MIN（不足T用已有长度）。'
      '展开到K0：按单元 endX 阶梯铺柱；十字 asOf 截断样本。'
      '当下性：会话 MathSeriesFreezeStore 格点首次非空写入后冻结，禁 activeUnit 整表回写；主图/十字读仓。'
      '十字 asOf：_paintPriceSeries 对 x>asOf 右侧不画（与蜡烛同构）。'
      '周期：设置面板「数学指标参数」（默认均线5,10,20；通道20,60），落盘 .chan_trend_model_config.json。'
      '呈现：主图连续折线（多T分色）；tooltip「K{n}均线」「K{n}通道」=各T读数。'
      '默认：进 catalog +「Kn指标」层全选 + 启动默认 K0。纯 Flutter，不改 Rust。'
      '与Kn趋势线/三型四型无关（序列统计≠段内拟合/分型几何）。',
    );
  }

  /// MACD/BOLL/RSI/KDJ/Demark（进程内去重）
  static bool _knMathClassicLoggedV6 = false;
  void appendKnMathClassicIndicators() {
    if (_knMathClassicLoggedV6) return;
    _knMathClassicLoggedV6 = true;
    append(
      '【Kn MACD/BOLL/RSI/KDJ/Demark·全层同构·v6·清副图Demark枚举+桶宽进Math】'
      '主图：K{n}布林(MID/UP/DOWN)；K{n}Demark（锚K0低点向上垂直排：S1…S9/C1…C13/完成买|完成卖）。'
      '副图：K{n}MACD(DIF/DEA线+柱)、K{n}RSI、K{n}KDJ；已删除 SubIndicatorKind.demark。'
      'Demark完成信号：Setup满9 与 Countdown满13 都算完整信号（各打「完成买/卖」）。'
      '设置（数学指标参数）：Demark三项下拉 + 背驰率 + 筹码桶宽输入框（最小0.01，笔数分布共用，落盘筹码配置）。'
      '分色：买红/橙、卖绿/青；完成信号更深加粗。'
      '输入：collectKnOhlcSamples(displayKn, unitBars+activeUnit)；K0 颗粒度 expandPointsToK0；asOf 截断。'
      '当下性：会话 MathSeriesFreezeStore 格点首次非空写入后冻结（含 Demark 标记内容），'
      '禁 Kn≥1 因 activeUnit/EMA 整表回写；主图/副图/十字读仓；参数变更清空并 0..当前步重冻。'
      '十字 asOf：均线/通道/布林/_paintPriceSeries 与副图 Math 一律 x>asOf 右侧不画（与蜡烛同构）。'
      'Kn绑定：Demark进主图「Kn指标」层全选（默认静音）；MACD/RSI/KDJ/背驰进副图「Kn指标」；启动默认仍不勾背驰。'
      '参数：Math 落盘 .chan_trend_model_config.json；桶宽落盘 .chan_chip_config.json。'
      'tooltip：macd_dif/dea/hist、boll_mid/up/down、rsi、kdj_k/d/j、demark_text（含完成买/卖）。'
      '默认：进 catalog +「Kn指标」层全选；纯 Flutter，不改 Rust。',
    );
  }

  /// Kn背驰 12 算法分项（进程内去重；非买卖点；已删 turnrate）
  static bool _knDivergenceLoggedV12 = false;
  void appendKnDivergenceIndicators() {
    if (_knDivergenceLoggedV12) return;
    _knDivergenceLoggedV12 = true;
    append(
      '【Kn背驰·副图分算法·v12·删turnrate】'
      '副图类别「背驰」：K{n}背驰_area/peak/…/斜率（12 算法×层；无 turnrate_avg，离线无换手）。'
      '绑定：进「Kn指标」层全选；启动默认不勾。'
      '口径：中枢判断±1 启动；相对最新动态中枢——'
      '动态Kn包中→上枢末vs上上枢末；破上/下沿→本枢末vs上枢末。'
      'ratio=out/in；diver 1/-1/0；divergence_rate 默认1.0（>100保送）。'
      '学习观察(可删)：勾选 area/peak/full_area/diff 任一自动并入同号 KnMACD 并立即绘制；'
      '十字 asOf 下 MACD 按算法差异高亮实际贡献柱（in蓝/out琥珀）：'
      'area=端点同号连续段；peak=整段同向柱+峰值描边；'
      'full_area=整段同向柱；diff=整段全部非空柱。'
      '全体 Kn背驰_* 副图同十字：高亮比较两段整 Kn 区间（in蓝/out琥珀）；'
      '含 slope（振幅摊平）/line_slope（显示名斜率）/amp/amount/volumn/amount_avg/volumn_avg/rsi 及 MACD 四算法。'
      'Kn背驰_斜率：与 Kn连线斜率同源 |(endVal-beginVal)/dx|；特征键 diver_line_slope_*；K0 无连线段不写。'
      'span/高亮来自 DivergenceFreezeStore；颗粒度K0；旧格冻结不回写。',
    );
  }

  /// 连线斜率背驰：ML 键 ASCII line_slope，界面仍写「斜率」（进程内去重）。
  static bool _diverLineSlopeAsciiLogged = false;
  void appendDiverLineSlopeAsciiKey() {
    if (_diverLineSlopeAsciiLogged) return;
    _diverLineSlopeAsciiLogged = true;
    append(
      '【Kn背驰_斜率·特征键 ASCII·2026-08-15】'
      '算法保留（与 Kn连线斜率同源）；ML/flatten 键改为 diver_line_slope_*（不再用汉字「斜率」）。'
      '副图芯片、十字 tip 仍显示 K{n}背驰_斜率。勿与旧 slope（振幅摊平）当成同一路。'
      'schema_version 仍为 1；旧 feature.meta / 旧模型须重导出并重训（sidecar 按特征名校验）。',
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

  /// Android：内置 a_Data 种子解压到应用私有目录（勿再走编译期桌面路径）。
  static bool _androidBundledDataLogged = false;
  void appendAndroidBundledDataRoot() {
    if (_androidBundledDataLogged) return;
    _androidBundledDataLogged = true;
    append(
      '【Android·a_Data】首次启动从 assets/a_data_seed.zip 解压到应用私有目录/a_Data；'
      '默认股票 002003（2025Q1 分笔）+ test；002003 默认区间=2025/01/02~2025/03/31。'
      '桌面仍可用环境变量 CHAN_DATA_ROOT 或 Rust 默认相对路径。',
    );
  }

  /// Android 手机布局：顶栏/底栏/设置抽屉，图表区最大化。
  static bool _androidMobileLayoutLogged = false;
  void appendAndroidMobileLayout() {
    if (_androidMobileLayoutLogged) return;
    _androidMobileLayoutLogged = true;
    append(
      '【Android·界面】顶栏=股票+周期+设置；无底栏播放条，默认左/中/右热区手势步进；'
      '设置用底部抽屉且开关即时刷新；主/副图各一收纳钮；主副图分割显式「调节」手柄；'
      '十字 tooltip 可上下滚动且右上角可关；无桌面窗控条。',
    );
  }

  /// 指标收纳、双指缩放/平移、策略回测上下分割（进程内去重）。
  static bool _androidTouchUiLogged = false;
  void appendAndroidTouchUiAndBacktestSplit() {
    if (_androidTouchUiLogged) return;
    _androidTouchUiLogged = true;
    append(
      '【指标收纳】主图/副图左上角各一「主图」「副图」按钮，默认收起 chip；点按展开/再点收纳。'
      '主图 chip 裁切在主图区；副图 chip 单行横滑且标记区保底高度。'
      '【手机双指】mobileLayout 下 K 线：双指捏合缩放 X、双指拖动平移；单指不拖图。'
      '【策略回测分割】打开策略回测后 K 线与工作台之间可拖分割条上下调整占比；'
      'Android 默认 K 线约 38%、桌面约 58%；拖条样式与图内主副图分割一致。',
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

  /// 设置「复制调试信息」按钮说明（进程内去重；文案随任务更新）。
  static bool _auditProbeCopyLogged = false;
  void appendAuditProbeCopyButton() {
    if (_auditProbeCopyLogged) return;
    _auditProbeCopyLogged = true;
    append(
      '【复制调试信息】设置面板常驻按钮（勿删）。'
      '当前绑定本批：T1 K1节奏关窗持值（分笔·77–114 续上个 0-0）；'
      'T2 tip 与主图节奏历史同源。'
      '跳末后点按；实现 audit_probe_snapshot.dart。',
    );
  }

  /// 本批：探针改会话/tip扫键 + Peak + 末枢sure + 口径文案 + asOf同源（进程内去重）。
  static bool _auditBatch2Logged = false;
  void appendAuditBatch2ProbePeakAsOf() {
    if (_auditBatch2Logged) return;
    _auditBatch2Logged = true;
    append(
      '【验收·本批】A探针改读会话历史+bar_features（告别冷前缀seg）；'
      'D探针实扫 tip「K*十一类BS」等最高类键；bsClassChinese 扩到二十防 K111 粘连。'
      'Rust：ZSCombineMode::Peak 按 DD/GG 重叠合并；删 export/collect 无 active 强制末枢 is_sure。'
      '口径：N类资格框每成员打点（≠1/2极值）；一类字母锁1Ba/1Sa；'
      'k1_*=structure0 虚拟K键名历史兼容≠displayKn=1。'
      'Flutter：十字下 painter levels/k0/zsK0 直接传 asOfBundle；'
      'msg_history 方案A层号文案改为方案B。须重编 chan_ffi.dll。',
    );
  }

  /// 本轮：BS冻结 / sure中枢 / bar_features / tip类上界（进程内去重）。
  static bool _auditFixBsZsFeatureLogged = false;
  void appendAuditFixBsZsFeature() {
    if (_auditFixBsZsFeatureLogged) return;
    _auditFixBsZsFeatureLogged = true;
    append(
      '【验收修复·BS冻结+sure中枢+bar_features】'
      'Rust：seg_idx→首次 discovery x 钉死（buy1/2）；'
      'try_combine 跳过已 is_sure 框；'
      'bar_features 增 zs_hits/bs1_hits（逐K pipeline 写入）。'
      'Flutter：tip 三类+上界跟 maxBsClass/会话最高类。'
      '须重编 chan_ffi.dll；复制调试信息看 A/B/C/D 判定。',
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

  /// 启动默认勾选「K0指标」层全选 + 非核心默认静音（进程内去重）。
  static bool _defaultIndicatorsK0LoggedV2 = false;
  void appendDefaultIndicatorsK0() {
    if (_defaultIndicatorsK0LoggedV2) return;
    _defaultIndicatorsK0LoggedV2 = true;
    append(
      '【默认指标·v2】主/副图启动仍勾选「K0指标」层全选（关联全集），'
      '与选择栏「Kn指标」同口径；但默认实际绘制仅：'
      '主图=Kn/Kn合并/Kn中枢/Kn连线；'
      '副图=Kn分型确认/Kn分型判断/Kn截断/Kn中枢确认/Kn中枢判断；'
      '其余关联项默认删除线灰度（muted，再点可打开绘制）；'
      '背驰 12 项启动仍不勾。新层全选新增的非核心项同样默认静音。'
      '截断随截断开关 prune。',
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
      '副图「Kn相邻比例」仍纳入「Kn指标」层全选与默认 K0 全选；'
      'Kn步进节奏已迁主图（见 appendStepRhythmToMainAndTipCats）；'
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
      '层内序（2026-08-08 起）：…→X类BS→背驰→比例/节奏→其它指标（均线等）。',
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

  /// tooltip 四准则：无未来/不回写/自洽/可作 ML（进程内去重）。
  static bool _tooltipFourRulesLogged = false;
  void appendTooltipFourRulesMlReady() {
    if (_tooltipFourRulesLogged) return;
    _tooltipFourRulesLogged = true;
    append(
      '【tooltip 四准则·2026-08-02】无未来/不回写/自洽/可作 ML：'
      '①十字 asOf 时中枢/levels 必须 asOfBundle；bundle 失败→空，禁回落会话末态；'
      '②十字 as-of K0合并框=Rust asOfBundle.frames（与合并序同源），禁 Dart 本地重建冒充；'
      '③标签「Kn上一中枢确认」=本框首根K时上一框 isSure（算法未改，仅正名）；'
      '④一类/二类/N类 BS 只扫会话 history（+显式 K0 帧入参），禁 levels 末态帧兜底；'
      '⑤副图叠柱买量≠tip B/S/G 三分解（bins→tick_side→全G）；ML 以 tip/metrics 三分解为准；'
      '⑥筹码峰/笔数峰动态后缀、节奏多行仅人对齐；ML 用底层 profile/history 固定键，勿解析 tip 动态行名。',
    );
  }

  /// 机器学习工作台：展望窗α + 测试锁定 + 漂移（进程内去重）。
  static bool _mlWorkbenchLogged = false;
  void appendMlWorkbenchHandoff() {
    if (_mlWorkbenchLogged) return;
    _mlWorkbenchLogged = true;
    append(
      '【机器学习·防未来/防窥探·2026-08-10】只基于当前股票；不展示K线图。'
      'α=发现后固定展望窗内 live一类+asOf截断极值（禁跳末末态）；时序训练|验证|测试；'
      '仅验证调参；测试只评估一次并锁定（改比例须退出重进）；报告标签√率与特征漂移。'
      '训练器可切逻辑回归(内存)/XGB(Python训+Rust推)：libsvm 0-based、missing=-9999999、'
      '模型名带 code/period/schema；强制重训可关仅当 sidecar 指纹一致。'
      '不改 tip 生产逻辑。详见 docs/ML_FEATURE_SPEC.md。',
    );
  }

  /// XGB 训推口径（进程内去重）。
  static bool _mlXgbLogged = false;
  void appendMlXgbTrainServe() {
    if (_mlXgbLogged) return;
    _mlXgbLogged = true;
    append(
      '【XGB训推·2026-08-10】样本只吃 Flutter MlBspExport；Python 自解析 0-based libsvm+CSR；'
      'valid early stop；sidecar 绑 feature_names/schema；Flutter 验证选阈值、测试只报一次；'
      'Rust ml_predict 读 default_left（缺省仍走左）；简化 walker≠完整 XGB。'
      '打包：pyinstaller ml_train_xgb.spec → windows/native/ml_train_xgb.exe（可回退 python 脚本）。',
    );
  }

  /// ML 特征数值化：BS/节奏/Demark 编码；字符串汇总禁入 flatten（进程内去重）。
  static bool _mlNumericFeaturesLogged = false;
  void appendMlNumericFeatures() {
    if (_mlNumericFeaturesLogged) return;
    _mlNumericFeaturesLogged = true;
    append(
      '【ML特征数值化·2026-08-10】tooltip 字符串汇总不变；'
      'BS 追加 *_code（方向×(类号×100+字母序)，如 1Ba→101）；'
      '节奏数组追加 labelInt（0-1→1）+ dirInt（up→+1/down→-1）；'
      'Demark 追加 demark_marks_{kn}={type,dir,idx}；'
      'forbidden：mean_text_/channel_text_/demark_text_/buy*_N、'
      'step_rhythm_lines_*[.label|.dir]、step_rhythm_N 展示键（禁 __has）；'
      '不改 Rust 计算与 tip 读数字符串键。',
    );
  }

  /// 交易条件变量目录阶段0（进程内去重）
  static bool _tradeCatalogPhase0Logged = false;
  void appendTradeSignalCatalogPhase0() {
    if (_tradeCatalogPhase0Logged) return;
    _tradeCatalogPhase0Logged = true;
    append(
      '【交易条件目录·阶段0·2026-08-15】'
      '回测先建「能拿来做条件的变量目录」，不在图上另判买卖箭头。'
      '本阶段已登记：K0开高低收量、各层虚拟K开高低收、各层布林中轨/上轨/下轨。'
      '同一层、同一套钟才能比较（K0收盘对K0布林；K1收盘对K1布林）。'
      '禁止用K0收盘去穿K1布林。布林读图上已冻住的格子，不另算一套。'
      '没有数=不可用，不是条件不成立；布林热身仍按图上出数，不另造前20根空白。'
      '中枢高低、一类/二类买卖点、三型四型、节奏、背驰只盘点、暂不进公式'
      '（框身份未写清，或需要「首次出现才触发」）。'
      '成交约定仍是：信号出在当根，下一根K0开盘才成交（本阶段尚未做撮合）。'
      '阶段0无图上买卖标记，不自动弹任务演示。',
    );
  }

  /// Clock + 契约 + K0成交钟（进程内去重）
  static bool _tradeClockContractLogged = false;
  void appendTradeClockContract() {
    if (_tradeClockContractLogged) return;
    _tradeClockContractLogged = true;
    append(
      '【交易钟·契约·K0成交·2026-08-15】'
      '比较和穿越必须同一层、同一套钟，否则在搭条件时就是非法，不会等回测跑完再查。'
      '例如 K1收盘对K1布林下轨可以；K0收盘对K1布林下轨直接禁止。'
      '条件只在该变量自己的计算钟上算，不能拿铺到K0格子上的阶梯当穿越。'
      '成交一律下一根K0开盘，没有下一根K3开盘。'
      '回测不另算一套指标，沿用现有逐步计算结果；策略箭头与缠论买卖点分开。'
      '本阶段仍只定契约，不做公式求值、撮合、账户。',
    );
  }

  /// CROSS 求值（进程内去重）
  static bool _tradeCrossEvalLogged = false;
  void appendTradeCrossEval() {
    if (_tradeCrossEvalLogged) return;
    _tradeCrossEvalLogged = true;
    append(
      '【穿越求值·2026-08-15】只做上穿/下穿。必须同一层同一套钟，读双方计算钟样本，'
      '相邻两根样本才判断穿越，只在边沿那一根打一次点。'
      'K1收盘对K1布林上/下轨可以；K0收盘对K1布林直接禁止。'
      '禁止用铺到K0格子上的阶梯做穿越。事件时间是当时已知的K0，看不到未来样本。'
      '连续待在轨外不重复触发。尚未做撮合、账户、策略箭头。',
    );
  }

  /// 最小交易闭环（进程内去重）
  static bool _tradeMiniLoopLogged = false;
  void appendTradeMiniLoop() {
    if (_tradeMiniLoopLogged) return;
    _tradeMiniLoopLogged = true;
    append(
      '【最小交易闭环·2026-08-15】穿越信号归一成买/卖后：当根知道、下一根K0开盘成交。'
      '没有下一根K0就不成交，不许拿最后收盘价虚构。'
      '第一版只做多、单仓：没仓才能买，有仓才能卖；再买/再卖直接拒绝。'
      'K1穿越也在下一根真实K0开盘成交，层号不改成交钟。'
      '布林只读图上已冻住的格子，禁止另算一套。手续费/滑点接口先留着、这阶段当0。'
      '尚未做净值、回撤、箭头、策略界面。',
    );
  }

  /// 回测结果引擎：净值 + 绩效（进程内去重）
  static bool _tradeBacktestResultLogged = false;
  void appendTradeBacktestResult() {
    if (_tradeBacktestResultLogged) return;
    _tradeBacktestResultLogged = true;
    append(
      '【回测结果引擎·2026-08-15】每一根K0记现金、持仓、净值、已实现/浮盈。'
      '净值=现金+持仓数量×该根收盘价，持仓期间必须计入浮盈浮亏，不能只看已平仓交易。'
      '期末若还持仓：没有闭合交易记录，但净值里仍有浮盈；结果分开记已平仓、未平仓、期末净值。'
      '收益：期末净值−本金。交易质量：胜率、盈亏因子、盈亏比、期望等；'
      '没有亏损交易时盈亏因子/盈亏比记成∞，不是让界面去猜NaN。'
      '最大回撤只看净值曲线（可定位开始/结束/回到前高的K），不要拿交易盈亏去代替回撤。'
      '本阶段仍无策略界面、无图上买卖箭头。',
    );
  }

  /// 策略回测工作台（进程内去重）
  static bool _tradeBacktestWorkbenchLogged = false;
  void appendTradeBacktestWorkbench() {
    if (_tradeBacktestWorkbenchLogged) return;
    _tradeBacktestWorkbenchLogged = true;
    append(
      '【策略回测工作台·2026-08-15】设置里打开策略回测。'
      '第一版只能选层号：该层收盘下穿该层布林下轨做买，该层收盘上穿该层布林上轨做卖；'
      '买和卖各自锁死同层，选不出K0收盘穿K1布林。'
      '运行后图上画「买」（红）/「卖2」（绿），只展示这一次回测的信号，不再算一遍，也不是缠论1Ba。'
      '报告直接端出净利润、收益率、胜率、盈亏比、盈亏因子、最大回撤、净值曲线和交易明细。'
      '交易与信号链路以表格展示；点交易会跳到入场K，再点同一笔跳出场；点图上买/卖2能追到订单和成交。'
      '每次运行记下引擎版本。未做做空、加仓、参数优化。',
    );
  }

  /// 通用交易条件构建器（进程内去重）
  static bool _tradeConditionBuilderLogged = false;
  void appendTradeConditionBuilder() {
    if (_tradeConditionBuilderLogged) return;
    _tradeConditionBuilderLogged = true;
    append(
      '【条件构建器·2026-08-15】买卖条件不再写死布林穿越。'
      '可以搭：大于/小于/大于等于/小于等于、上穿、下穿，多条用 AND 或 OR 组合；'
      '右边可以是同一层的收开高低或布林三轨，也可以填常数。'
      '同一条比较必须同层同钟：K1收盘对K1布林可以，K0收盘对K1布林直接禁止；'
      '一棵树上也不能把 K0 和 K1 AND/OR 在一起。'
      '真假只由回测引擎按这棵条件树计算，界面只负责搭树、展示结果。'
      '每条买/卖2会写出条件、触发时的取值、发现在哪根K0，并能追到订单和成交。'
      '本批变量只有收开高低和布林三轨，未接入 MACD/RSI/买卖点/背驰。',
    );
  }

  /// 指标变量扩展层（进程内去重）
  static bool _tradeIndicatorVarsLogged = false;
  void appendTradeIndicatorVars() {
    if (_tradeIndicatorVarsLogged) return;
    _tradeIndicatorVarsLogged = true;
    append(
      '【指标变量·2026-08-15】条件积木按层和类别选变量：开高低收、布林、MACD（DIF/DEA/柱）、RSI、KDJ；'
      '成交量这一版只开放 K0，没有另造 Kn 成交量和均量。'
      'MACD/RSI/KDJ 只读图上已冻住的格子，没有仓就是不可用，不会现场再算一遍。'
      '和布林同一套钟：K0 一根一根，K1 及以上看虚拟K右端。'
      'K1 的 MACD DIF 上穿 DEA 可以；K0 的 MACD 对 K1 的 RSI 直接禁止。'
      '左侧变量诊断能看到来源、计算钟、显示格子、当时已知的 K0 和当前值。'
      '未接入买卖点、背驰、节奏、Demark。',
    );
  }

  /// 缠论结构事件变量（进程内去重）
  static bool _tradeChanEventsLogged = false;
  void appendTradeChanEvents() {
    if (_tradeChanEventsLogged) return;
    _tradeChanEventsLogged = true;
    append(
      '【结构事件·2026-08-15】一类/二类买卖点、分型确认、中枢确认进条件积木，都是「出现一次」的事件，'
      '不是一直为真的状态。动态段后面几根 K 即使还挂着同一个点，交易信号也不再重复打。'
      '事件只能跟同层同钟用 AND/OR 拼，不能拿去比大小或上穿下穿。'
      '分型确认是连线钟，不能直接和 RSI 拼；一类买点和 RSI 同属中枢那套钟，可以拼。'
      '未来才确认的点不会写进过去的回测。未接入 N 类、中枢高低、背驰、节奏。',
    );
  }

  /// 中枢结构对象 + 确认中枢数值（进程内去重）
  static bool _tradeZsObjectsLogged = false;
  void appendTradeZsObjects() {
    if (_tradeZsObjectsLogged) return;
    _tradeZsObjectsLogged = true;
    append(
      '【确认中枢数值·2026-08-15】中枢先当成有身份的对象：同一个框动态拉长，编号不变。'
      '策略只用「这一层当前最新一个已经确认、当时已经能看见的中枢」的高/低/中轴，'
      '不是事后扩大后的末态，也不是未确认的框。没有确认中枢就是不可用，不会填成 0。'
      'K1 收盘可以跟 K1 中枢低比；K0 收盘不能跟 K1 中枢比。'
      '中枢确认仍是「出现一次」的事件，不能拿去比大小或上穿下穿，但可以和同层收盘低于中枢低拼在一起。'
      '未接入未确认中枢、N 类、背驰、节奏、三型四型。',
    );
  }

  /// 背驰结构关系变量（进程内去重）
  static bool _tradeDivergenceRelLogged = false;
  void appendTradeDivergenceRelations() {
    if (_tradeDivergenceRelLogged) return;
    _tradeDivergenceRelLogged = true;
    append(
      '【背驰关系·2026-08-15】背驰不是「这根 K 看起来像背驰」，而是：哪一个结构对比哪一个结构、在哪根 K0 被发现。'
      '第一版只开放已经确认的 MACD 面积背驰：出现一次、力度比、方向（向上/向下）。'
      '出现是事件，不能比大小或上穿下穿；力度比可以和数字比；方向只能等于向上或向下。'
      '同一个比较对象后面再拉长，关系编号不变；当时已经记下的力度比不会被以后改掉。'
      '确认程度变了会记成新事件，不回写旧记录。没有当时可见的背驰就是不可用，不是 0。'
      '可以和同层一类买点、RSI 拼。未接入其它背驰算法、N 类、节奏、三型四型、做空、加仓。',
    );
  }

  /// N 类事件 + 结构契约 + 条件树 v2 + 归因（进程内去重）
  static bool _tradeChanCompleteLogged = false;
  void appendTradeChanComplete() {
    if (_tradeChanCompleteLogged) return;
    _tradeChanCompleteLogged = true;
    append(
      '【缠论交易变量收口·2026-08-16】三类及以上买卖点用 BUY_N(3)、SELL_N(3) 这种带类号的事件，不再为每一类单独起名字。'
      '出现一次才出信号，动态段后面几根 K 还挂着同一个点也不会重复下单。'
      '中枢和背驰接到同一套结构编号：对象有 objectId，关系有 relationId，策略只用当时已经能看见的投影。'
      '条件树会在编译时分清类型错、混钟、不可用三种失败，不会再一律叫 invalid。'
      '每笔信号能看见完整求值链；回测报告多了按买卖规则的归因，以及引擎/策略/契约/结构四套版本号。'
      '成交仍是下一根 K0 开盘。未接入做空、加仓、多品种、参数优化、全市场选股。',
    );
  }

  /// 事件脉冲 + 同一根先平后开（对齐金字塔 CROSS / 平仓在前）
  static bool _tradeEventPulseLogged = false;
  void appendTradeEventPulse() {
    if (_tradeEventPulseLogged) return;
    _tradeEventPulseLogged = true;
    append(
      '【事件脉冲·先平后开·2026-08-16】分型确认、一类买点这类「出现」条件，'
      '按当根脉冲出信号：连着两颗不同确认（例如 K0 7 和 8）各打一次，不再用假变真把第二颗吞掉。'
      '同一分型动态段后面几根还挂着，仍只认第一次。'
      '收盘大于均线这类状态比较，继续假变真，避免条件一直成立就每根都买。'
      '同一根既有买又有卖：先平后开（空仓只开，有仓先平再开）。成交仍是下一根 K0 开盘。'
      '未拆顶确认/底确认积木；未做做空、加仓、当根收盘成交。',
    );
  }

  /// 策买画在发现根；被拒不画；交易写成交时间；拖动跟着 K 线
  static bool _tradeSignalDisplayLogged = false;
  void appendTradeSignalDisplay() {
    if (_tradeSignalDisplayLogged) return;
    _tradeSignalDisplayLogged = true;
    append(
      '【策买显示·2026-08-17】图上买/卖2画在发现当根，被拒的不画（空仓时的卖不出现绿三角）。'
      '真正成交在下一根开盘：交易明细写成交那根的时间和K号，并注明信号在哪根，方便和图上的红/绿三角对上。'
      '拖动或缩放 K 线时，买/卖2跟着蜡烛走，不再停在原地。',
    );
  }

  /// 买/卖2 红绿标签；交易与信号链路表格
  static bool _tradeSignalTableLogged = false;
  void appendTradeSignalTable() {
    if (_tradeSignalTableLogged) return;
    _tradeSignalTableLogged = true;
    append(
      '【策略标记·表格报告·2026-08-18】主图策略信号改名：买（红）、卖2（绿），与缠论 1Ba/1Sa 区分。'
      '回测报告「交易」「信号链路」改为表格：列对齐、可横滑；点行仍跳 K 线并联动高亮。'
      '被拒信号仍不画；成交仍在下一根开盘。',
    );
  }

  /// 策略回测成交价格可选（进程内去重）
  static bool _tradeFillPriceModeLogged = false;
  void appendTradeFillPriceMode() {
    if (_tradeFillPriceModeLogged) return;
    _tradeFillPriceModeLogged = true;
    append(
      '【回测成交价格·2026-08-18】策略设置里可选成交价格（买点/卖点共用）：'
      '本周期收盘价（默认）= 信号在第 N 根成立时按第 N 根收盘成交；'
      '次周期开盘价 = 按第 N+1 根开盘成交（无下一根则无法成交）。'
      '图上买/卖2仍在发现根；交易明细写实际成交K。同一根先平后开不变。',
    );
  }

  /// 策略买卖按组合组编号（进程内去重）
  static bool _tradeRoundLabelLogged = false;
  void appendTradeRoundLabel() {
    if (_tradeRoundLabelLogged) return;
    _tradeRoundLabelLogged = true;
    append(
      '【策略买卖组号·2026-08-19】闭合交易按顺序编号：买1+卖1 为第一组，买2+卖2 为第二组。'
      '主图与报告「交易」「信号链路」同步显示买1/卖1；期末仍持仓只有买N、尚无卖N。'
      '被拒/过期信号不进组号；与缠论 1Ba/1Sa 仍分开。',
    );
  }

  /// 回测变量目录补全（进程内去重）
  static bool _tradeCatalogFullLogged = false;
  void appendTradeCatalogFull() {
    if (_tradeCatalogFullLogged) return;
    _tradeCatalogFullLogged = true;
    append(
      '【回测变量补全·2026-08-20】图上已经算好的，策略公式按同一份冻结仓/会话历史接入，不解析十字文案、不另算一套。'
      '未确认中枢高/低/中轴是单独变量：这根 K 盖住未确认框才有数，没有就空，不填 0、不沿用上一根；当步写入后冻结。'
      '已确认中枢 CURRENT 照旧。均线/通道读冻结仓；Demark 完成买/卖当根脉冲；分型判断/中枢判断首次可判出一次。'
      '连线斜率、相邻比例、节奏是连线钟，不能和布林/RSI 直接比。三型/四型/趋势线是线投影到价，可与同层收盘/布林比。'
      'K1+ 成交量/笔数按铺平层序列、跟 MACD 同一套计算钟取样。'
      'K0筹码峰/笔数峰按这根高低编号（-1/+1），峰价可与开高低收比；没有那一颗就空。'
      '整段中枢/整段背驰仍不能当一个数比。',
    );
  }

  /// 筹码峰/笔数峰进公式（进程内去重）
  static bool _chipPeakVarsLogged = false;
  void appendChipPeakVars() {
    if (_chipPeakVarsLogged) return;
    _chipPeakVarsLogged = true;
    append(
      '【筹码峰进公式·2026-08-20】K0筹码峰/笔数峰按这根 K 的高低框编号：框下最近-1、框上最近+1，框内无号。'
      '公式比的是峰价和开高低收，不解析十字文字。没有那一颗就空，不填 0、不沿用；当步冻结。'
      '只做 K0，和收盘同一套钟。斜率仍不和布林混写。',
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
