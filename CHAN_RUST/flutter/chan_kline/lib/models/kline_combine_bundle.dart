import 'k0_confirm_signal.dart';
import 'bar_crosshair_feature.dart';
import 'buy1_frame.dart';
import 'sell1_frame.dart';
import 'buy2_frame.dart';
import 'sell2_frame.dart';
import 'buy_n_frame.dart';
import 'sell_n_frame.dart';
import 'bs_verdict_frame.dart';
import 'k0_line.dart';
import 'k1_bar.dart';
import 'kline_combine_frame.dart';
import 'level_models.dart';
import 'k1_analysis.dart';
import 'zs_frame.dart';

/// Rust `KlineCombineBundle`：合并线框 + K0连线确认 + 十字线特征 + K0连线链 + Kn 流水线。
class KlineCombineBundle {
  final List<KlineCombineFrame> frames;
  final List<K0ConfirmSignal> k0Confirms;
  final List<BarCrosshairFeature> barFeatures;
  final List<K0Line> k0Lines;
  final K1AnalysisBundle k1Analysis;
  final List<K1Bar> k1Bars;
  final List<KlineCombineFrame> k1CombineFrames;
  final String defaultK0Policy;

  /// 全层首段策略（index 0=K1/K0连线，1=K2/K1连线，…）
  final List<String> defaultSegmentPolicies;

  /// 全层冻结段链
  final List<List<K0Line>> levelSegments;

  /// 全层展示用虚拟段 K（pending + 冻结 + 进行中）
  final List<List<K1Bar>> levelVirtualUnits;

  /// Kn 流水线全量输出（levels[0]=K1/K0连线，levels[1]=K2/K1连线，…穷尽）
  final List<LevelBundle> levels;

  /// K0中枢（原生分钟K段，level=0）
  final List<ZSFrame> zsK0Frames;

  /// K0一买（与 K0中枢同层）
  final List<Buy1Frame> buy1K0Frames;

  /// K0一卖（一买镜像；与 K0中枢同层）
  final List<Sell1Frame> sell1K0Frames;

  /// K0二买（与一类同框）
  final List<Buy2Frame> buy2K0Frames;

  /// K0二卖（二买镜像）
  final List<Sell2Frame> sell2K0Frames;

  /// K0三类+买（链升类）
  final List<BuyNFrame> buyNK0Frames;

  /// K0三类+卖（买镜像）
  final List<SellNFrame> sellNK0Frames;

  /// K0 BSP 在线评判（独立于原 BSP）
  final List<BsVerdictFrame> bsVerdictK0Frames;

  const KlineCombineBundle({
    required this.frames,
    required this.k0Confirms,
    this.barFeatures = const [],
    this.k0Lines = const [],
    this.k1Analysis = const K1AnalysisBundle(),
    this.k1Bars = const [],
    this.k1CombineFrames = const [],
    this.defaultK0Policy = 'pending',
    this.defaultSegmentPolicies = const [],
    this.levelSegments = const [],
    this.levelVirtualUnits = const [],
    this.levels = const [],
    this.zsK0Frames = const [],
    this.buy1K0Frames = const [],
    this.sell1K0Frames = const [],
    this.buy2K0Frames = const [],
    this.sell2K0Frames = const [],
    this.buyNK0Frames = const [],
    this.sellNK0Frames = const [],
    this.bsVerdictK0Frames = const [],
  });

  factory KlineCombineBundle.fromJson(
    Map<String, dynamic> json, {
    bool slim = false,
  }) {
    return KlineCombineBundle(
      frames: (json['frames'] as List? ?? const [])
          .map(
            (e) => KlineCombineFrame.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList(),
      k0Confirms: (json['k0_confirms'] as List? ?? const [])
          .map(
            (e) => K0ConfirmSignal.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList(),
      barFeatures: (json['bar_features'] as List? ?? const [])
          .map(
            (e) => BarCrosshairFeature.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList(),
      k0Lines: (json['k0_lines'] as List? ?? const [])
          .map(
            (e) => K0Line.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList(),
      k1Analysis: slim
          ? K1AnalysisBundle.empty()
          : json['k1_analysis'] is Map
              ? K1AnalysisBundle.fromJson(
                  Map<String, dynamic>.from(json['k1_analysis'] as Map),
                )
              : K1AnalysisBundle.empty(),
      k1Bars: slim
          ? const []
          : (json['k1_bars'] as List? ?? const [])
              .map(
                (e) => K1Bar.fromJson(
                  Map<String, dynamic>.from(e as Map),
                ),
              )
              .toList(),
      k1CombineFrames: slim
          ? const []
          : (json['k1_combine_frames'] as List? ?? const [])
              .map(
                (e) => KlineCombineFrame.fromJson(
                  Map<String, dynamic>.from(e as Map),
                ),
              )
              .toList(),
      defaultK0Policy: json['default_k0_policy'] as String? ?? 'pending',
      defaultSegmentPolicies: (json['default_segment_policies'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(),
      levelSegments: slim
          ? const []
          : (json['level_segments'] as List? ?? const [])
              .map(
                (layer) => (layer as List)
                    .map(
                      (e) => K0Line.fromJson(
                        Map<String, dynamic>.from(e as Map),
                      ),
                    )
                    .toList(),
              )
              .toList(),
      levelVirtualUnits: slim
          ? const []
          : (json['level_virtual_units'] as List? ?? const [])
              .map(
                (layer) => (layer as List)
                    .map(
                      (e) => K1Bar.fromJson(
                        Map<String, dynamic>.from(e as Map),
                      ),
                    )
                    .toList(),
              )
              .toList(),
      levels: (json['levels'] as List? ?? const [])
          .map(
            (e) => LevelBundle.fromJson(
              Map<String, dynamic>.from(e as Map),
              slim: slim,
            ),
          )
          .toList(),
      zsK0Frames: (json['zs_k0_frames'] as List? ?? const [])
          .map((e) => ZSFrame.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      buy1K0Frames: (json['buy1_k0_frames'] as List? ?? const [])
          .map((e) => Buy1Frame.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      sell1K0Frames: (json['sell1_k0_frames'] as List? ?? const [])
          .map((e) => Sell1Frame.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      buy2K0Frames: (json['buy2_k0_frames'] as List? ?? const [])
          .map((e) => Buy2Frame.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      sell2K0Frames: (json['sell2_k0_frames'] as List? ?? const [])
          .map((e) => Sell2Frame.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      buyNK0Frames: (json['buy_n_k0_frames'] as List? ?? const [])
          .map((e) => BuyNFrame.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      sellNK0Frames: (json['sell_n_k0_frames'] as List? ?? const [])
          .map((e) => SellNFrame.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      bsVerdictK0Frames: (json['bs_verdict_k0_frames'] as List? ?? const [])
          .map((e) =>
              BsVerdictFrame.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }

  /// 只换 bar_features（步退时用当前仓前缀补上 slim 快照里故意没钉的逐根特征）。
  KlineCombineBundle withBarFeatures(List<BarCrosshairFeature> feats) {
    return KlineCombineBundle(
      frames: frames,
      k0Confirms: k0Confirms,
      barFeatures: feats,
      k0Lines: k0Lines,
      k1Analysis: k1Analysis,
      k1Bars: k1Bars,
      k1CombineFrames: k1CombineFrames,
      defaultK0Policy: defaultK0Policy,
      defaultSegmentPolicies: defaultSegmentPolicies,
      levelSegments: levelSegments,
      levelVirtualUnits: levelVirtualUnits,
      levels: levels,
      zsK0Frames: zsK0Frames,
      buy1K0Frames: buy1K0Frames,
      sell1K0Frames: sell1K0Frames,
      buy2K0Frames: buy2K0Frames,
      sell2K0Frames: sell2K0Frames,
      buyNK0Frames: buyNK0Frames,
      sellNK0Frames: sellNK0Frames,
      bsVerdictK0Frames: bsVerdictK0Frames,
    );
  }

  static KlineCombineBundle empty() => const KlineCombineBundle(
        frames: [],
        k0Confirms: [],
        barFeatures: [],
        k0Lines: [],
        k1Analysis: K1AnalysisBundle(),
        k1Bars: [],
        k1CombineFrames: [],
        defaultK0Policy: 'pending',
        defaultSegmentPolicies: [],
        levelSegments: [],
        levelVirtualUnits: [],
        levels: [],
        zsK0Frames: [],
        buy1K0Frames: [],
        sell1K0Frames: [],
        buy2K0Frames: [],
        sell2K0Frames: [],
        buyNK0Frames: [],
        sellNK0Frames: [],
        bsVerdictK0Frames: [],
      );
}
