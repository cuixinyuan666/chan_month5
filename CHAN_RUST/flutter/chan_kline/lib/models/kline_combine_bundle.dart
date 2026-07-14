import 'k0_confirm_signal.dart';
import 'bar_crosshair_feature.dart';
import 'k0_line.dart';
import 'k1_bar.dart';
import 'kline_combine_frame.dart';
import 'level_models.dart';
import 'k1_analysis.dart';

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
  });

  factory KlineCombineBundle.fromJson(Map<String, dynamic> json) {
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
      k1Analysis: json['k1_analysis'] is Map
          ? K1AnalysisBundle.fromJson(
              Map<String, dynamic>.from(json['k1_analysis'] as Map),
            )
          : K1AnalysisBundle.empty(),
      k1Bars: (json['k1_bars'] as List? ?? const [])
          .map(
            (e) => K1Bar.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList(),
      k1CombineFrames: (json['k1_combine_frames'] as List? ?? const [])
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
      levelSegments: (json['level_segments'] as List? ?? const [])
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
      levelVirtualUnits: (json['level_virtual_units'] as List? ?? const [])
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
          .map((e) => LevelBundle.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
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
      );
}
