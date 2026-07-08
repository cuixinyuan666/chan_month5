import 'bi_confirm_signal.dart';
import 'bar_crosshair_feature.dart';
import 'bi_segment.dart';
import 'bi_virtual_bar.dart';
import 'kline_combine_frame.dart';
import 'seg_analysis.dart';

/// Rust `KlineCombineBundle`：合并线框 + 笔确认 + 十字线特征 + 笔段链 + 段分析。
class KlineCombineBundle {
  final List<KlineCombineFrame> frames;
  final List<BiConfirmSignal> biConfirms;
  final List<BarCrosshairFeature> barFeatures;
  final List<BiSegment> biSegments;
  final SegAnalysisBundle segAnalysis;
  final List<BiVirtualBar> biVirtualBars;
  final List<KlineCombineFrame> biCombineFrames;
  final String defaultBiPolicy;

  const KlineCombineBundle({
    required this.frames,
    required this.biConfirms,
    this.barFeatures = const [],
    this.biSegments = const [],
    this.segAnalysis = const SegAnalysisBundle(),
    this.biVirtualBars = const [],
    this.biCombineFrames = const [],
    this.defaultBiPolicy = 'pending',
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
      biConfirms: (json['bi_confirms'] as List? ?? const [])
          .map(
            (e) => BiConfirmSignal.fromJson(
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
      biSegments: (json['bi_segments'] as List? ?? const [])
          .map(
            (e) => BiSegment.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList(),
      segAnalysis: json['seg_analysis'] is Map
          ? SegAnalysisBundle.fromJson(
              Map<String, dynamic>.from(json['seg_analysis'] as Map),
            )
          : SegAnalysisBundle.empty(),
      biVirtualBars: (json['bi_virtual_bars'] as List? ?? const [])
          .map(
            (e) => BiVirtualBar.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList(),
      biCombineFrames: (json['bi_combine_frames'] as List? ?? const [])
          .map(
            (e) => KlineCombineFrame.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList(),
      defaultBiPolicy: json['default_bi_policy'] as String? ?? 'pending',
    );
  }

  static KlineCombineBundle empty() => const KlineCombineBundle(
        frames: [],
        biConfirms: [],
        barFeatures: [],
        biSegments: [],
        segAnalysis: SegAnalysisBundle(),
        biVirtualBars: [],
        biCombineFrames: [],
        defaultBiPolicy: 'pending',
      );
}
