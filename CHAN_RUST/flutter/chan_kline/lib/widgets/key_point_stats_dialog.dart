import 'package:flutter/material.dart';

import '../key_point_stats/key_point_collect.dart';
import '../key_point_stats/key_point_stat_align.dart';
import '../key_point_stats/key_point_stat_export.dart';
import '../key_point_stats/key_point_stat_runner.dart';
import '../models/bar_feature_lookup.dart';
import '../models/k0_confirm_signal.dart';
import '../models/k0_line.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import '../models/math_indicator_config.dart';
import '../settings/key_point_stats_settings_store.dart';

import 'key_point_stats_result_panel.dart';

/// 计优对话框：收集关键点位 → 读冻结账 → 出统计表 → 落盘 JSON/TSV。
///
/// 与寻优同前置：主图已步进到区间最后一根 K，缠论与指标冻结仓已跑完。
/// **只读**冻结账，不写回任何指标，不改主图语义。
class KeyPointStatsDialog extends StatefulWidget {
  const KeyPointStatsDialog({
    super.key,
    required this.code,
    required this.period,
    required this.beginText,
    required this.endText,
    required this.bars,
    required this.levels,
    required this.lookup,
    required this.maxKn,
    this.k0Confirms = const [],
    this.k0Lines = const [],
    this.truncationCheck = true,
    this.maxBsClass = 9,
    this.mathConfig = const MathIndicatorConfig(),
    this.chipBucketStep = 0.01,
    this.peakRankMode = 'spatial',
    /// 仅供机器人验证的 Widget 测试注入：直接给定统计结果，跳过真跑。
    this.resultOverride,
  });

  final String code;
  final String period;
  final String beginText;
  final String endText;
  final List<KlineBar> bars;
  final List<LevelBundle> levels;
  final BarFeatureLookup lookup;
  final int maxKn;
  final List<K0ConfirmSignal> k0Confirms;
  final List<K0Line> k0Lines;

  /// 复现参数用：截断开关会改转折点位置，必须随表一起记。
  final bool truncationCheck;

  final int maxBsClass;
  final MathIndicatorConfig mathConfig;
  final double chipBucketStep;
  final String peakRankMode;
  final KeyPointStatResult? resultOverride;

  @override
  State<KeyPointStatsDialog> createState() => _KeyPointStatsDialogState();
}

class _KeyPointStatsDialogState extends State<KeyPointStatsDialog> {
  String _phase = '准备';
  String _detail = '';
  bool _running = true;
  String? _error;
  KeyPointStatResult? _result;
  String _jsonPath = '';
  String _tsvPath = '';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    await KeyPointStatSettingsStore.load();
    final settings = KeyPointStatSettingsStore.current;
    try {
      setState(() {
        _phase = '收集关键点位';
        _detail = '共 ${widget.bars.length} 根 K0 · asOf=${_asOf()}';
      });
      await Future<void>.delayed(Duration.zero);

      final override = widget.resultOverride;
      final KeyPointStatResult result;
      if (override != null) {
        result = override;
      } else {
        if (widget.bars.isEmpty) throw Exception('区间内无 K 线');
        if (widget.lookup.byIdx.isEmpty) {
          throw Exception('主图冻结账为空：请先步进 K 线再点计优');
        }
        final collect = collectKeyPoints(
          bars: widget.bars,
          levels: widget.levels,
          k0Confirms: widget.k0Confirms,
          k0Lines: widget.k0Lines,
          asOf: _asOf(),
        );
        setState(() {
          _phase = '统计指标';
          _detail = '关键点位 ${collect.keyPoints.length} 个 · ${settings.replayLine}';
        });
        await Future<void>.delayed(Duration.zero);

        result = KeyPointStatRunner.run(
          lookup: widget.lookup,
          collect: collect,
          settings: settings,
          code: widget.code,
          period: widget.period,
          beginText: widget.beginText,
          endText: widget.endText,
          barCount: widget.bars.length,
          maxKn: widget.maxKn,
          align: KeyPointStatAlign(
            code: widget.code,
            period: widget.period,
            beginText: widget.beginText,
            endText: widget.endText,
            barCount: widget.bars.length,
            asOf: _asOf(),
            maxKn: widget.maxKn,
            truncationCheck: widget.truncationCheck,
            maxBsClass: widget.maxBsClass,
            mathConfig: widget.mathConfig,
            bucketStep: widget.chipBucketStep,
            peakRankMode: widget.peakRankMode,
          ),
        );
      }

      setState(() {
        _phase = '落盘';
        _detail = '写 JSON / TSV';
      });
      await Future<void>.delayed(Duration.zero);
      final tsv = await KeyPointStatExport.writeAll(result);
      final json = await KeyPointStatSettingsStore.resultsFile(
        code: result.code,
        period: result.period,
      );

      if (!mounted) return;
      setState(() {
        _result = result;
        _jsonPath = json.path;
        _tsvPath = tsv.path;
        _phase = '完成';
        _detail = '';
        _running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _running = false;
      });
    }
  }

  int _asOf() => widget.bars.isEmpty ? -1 : widget.bars.last.idx;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final w = size.width > 1000 ? 960.0 : size.width * 0.94;
    final h = size.height > 720 ? 660.0 : size.height * 0.86;
    return AlertDialog(
      title: Text('计优 · ${widget.code} ${widget.period}'),
      content: SizedBox(
        width: w,
        height: h,
        child: _error != null
            ? SingleChildScrollView(
                child: Text(
                  '计优失败：$_error',
                  style: const TextStyle(fontSize: 13, height: 1.5),
                ),
              )
            : _result == null
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '正在$_phase…',
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 6),
                      if (_detail.isNotEmpty)
                        Text(
                          _detail,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      const Spacer(),
                    ],
                  )
                : KeyPointStatsResultPanel(
                    result: _result!,
                    jsonPath: _jsonPath,
                    tsvPath: _tsvPath,
                  ),
      ),
      actions: [
        TextButton(
          onPressed: _running ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
/// 设置 · 计优说明（操作逻辑 + 统计口径）。
Future<void> showKeyPointStatsHelp(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => SelectionArea(child: AlertDialog(
      title: const Text('计优说明'),
      content: const SingleChildScrollView(
        child: Text(
          '作用：把「已经跑完的缠论与指标」在关键点位上做一次汇总统计。\n'
          '它不改任何指标、不回写冻结仓，只读账本。\n\n'
          '关键点位（本阶段）\n'
          '· 各级别连线的转折点（顶 / 底）：\n'
          '  - K0 连线（旧称笔）：分型组里的极值 K；\n'
          '  - K1… 连线（旧称 N 段）：每段的起止端点 K；\n'
          '· 只统计「已确认冻结」的转折点；还在走、没确认的段不算数。\n\n'
          '取值口径\n'
          '· 取转折极点 K 那一根的指标冻结值 —— 图形上转折真正发生的那根 K。\n'
          '· 数据源是主图逐 K 冻结账（与十字线、机器学习同源），不会另算第二套。\n'
          '· 同时记录确认当步 K（confirmX）供审计，但不参与取值。\n\n'
          '统计方式\n'
          '· 数值型：样本数 / 非空率 / 平均数 / 中位数 / 标准差 / 最小 / 最大 / P25 / P75 / 众数；\n'
          '· 类别型（如顶/底、是否截断、背驰标志）：样本数 / 精确众数 / 众数占比；\n'
          '· 数值众数是按小数位分桶的近似值（面板会写桶宽），类别众数才是精确值；\n'
          '· 没有样本一律显示「—」，不补 0、不拿上一根的值顶替。\n\n'
          '关于「当下性」\n'
          '· 计优是跑完之后回头统计，按 AGENTS.md 属于事后统计例外；\n'
          '· 转折点是回头认定的，但读到的每个指标值仍然只用该 K 及之前的数据。\n\n'
          '操作步骤\n'
          '1. 设置里选好股票、周期、起止时间，先「加载 K 线」。\n'
          '2. 步进到区间最后一根 K（缠论与指标此时才全部跑完；可一键跳末）。\n'
          '3. 点「计优」：自动收集转折点 → 读冻结账 → 出统计表。\n'
          '4. 结果按「级别 × 顶/底」分 Tab，可切「数值型 / 类别型」过滤，点表头可排序。\n'
          '5. 完整结果同时写 JSON 与 TSV（应用支持目录 key_point_stats_*.json/.tsv）。\n'
          '6. 想改分组方式或众数桶宽，点设置里的「计优参数」。\n\n'
          '注意：样本太少时统计没有意义（可设分组样本下限）；\n'
          '本结果仅供研究复盘，不构成投资建议。',
          style: TextStyle(fontSize: 13, height: 1.45),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('知道了'),
        ),
      ],
    )),
  );
}
/// 设置 · 计优参数（分组方式 / 众数桶宽 / 分组样本下限）。
Future<KeyPointStatSettings?> showKeyPointStatsSettingsSheet(
  BuildContext context,
) async {
  await KeyPointStatSettingsStore.load();
  var cfg = KeyPointStatSettingsStore.current;
  if (!context.mounted) return null;
  return showModalBottomSheet<KeyPointStatSettings>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '计优参数',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              SwitchListTile(
                title: const Text('按级别 × 顶/底 分组'),
                subtitle: const Text(
                  '开启：K1顶/K1底/K2顶… 各一张表；关闭：每级顶底合并成一张表',
                ),
                value: cfg.splitTopBottom,
                onChanged: (v) =>
                    setLocal(() => cfg = cfg.copyWith(splitTopBottom: v)),
              ),
              ListTile(
                title: Text(
                  '数值众数桶宽：${cfg.modeDigits <= 0 ? '整数' : '10^-${cfg.modeDigits}'}',
                ),
                subtitle: const Text(
                  '数值型众数是分桶近似；桶越窄越接近原值、但可能每个值都只出现一次',
                ),
              ),
              Slider(
                value: cfg.modeDigits.toDouble(),
                min: 0,
                max: 8,
                divisions: 8,
                label: '${cfg.modeDigits}',
                onChanged: (v) =>
                    setLocal(() => cfg = cfg.copyWith(modeDigits: v.round())),
              ),
              ListTile(
                title: Text(
                  '众数显著性阈值：${(cfg.modeMinShare * 100).round()}%',
                ),
                subtitle: const Text(
                  '数值型众数是分桶近似；桶命中占比低于此值就标「无显著众数」，'
                  '不再拿一个只出现过一次的值冒充众数（类别型众数不受影响，它本来就是精确的）',
                ),
              ),
              Slider(
                value: cfg.modeMinShare,
                min: 0,
                max: 1,
                divisions: 10,
                label: '${(cfg.modeMinShare * 100).round()}%',
                onChanged: (v) =>
                    setLocal(() => cfg = cfg.copyWith(modeMinShare: v)),
              ),
              ListTile(
                title: Text('分组样本下限：${cfg.minPoints}'),
                subtitle: const Text('转折点数少于该值的分组不出表，避免 1~2 个样本误导'),
              ),
              Slider(
                value: cfg.minPoints.toDouble().clamp(1, 20),
                min: 1,
                max: 20,
                divisions: 19,
                label: '${cfg.minPoints}',
                onChanged: (v) =>
                    setLocal(() => cfg = cfg.copyWith(minPoints: v.round())),
              ),
              Text(
                '当前口径：${cfg.replayLine}',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('取消'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () async {
                      await KeyPointStatSettingsStore.save(cfg);
                      if (!ctx.mounted) return;
                      Navigator.pop(ctx, cfg);
                    },
                    child: const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}