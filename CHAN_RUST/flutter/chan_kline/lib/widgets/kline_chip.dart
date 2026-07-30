import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/chip_config.dart';

/// Rust/Dart 共用的筹码分桶结果。
class ChipProfileData {
  const ChipProfileData({
    required this.profileId,
    required this.cutoffX,
    required this.bucketStep,
    required this.prices,
    required this.s,
    required this.b,
    required this.total,
    required this.maxTotal,
    this.source = 'rust',
  });

  final String profileId;
  final int cutoffX;
  final double bucketStep;
  final List<double> prices;
  final List<double> s;
  final List<double> b;
  final List<double> total;
  final double maxTotal;
  final String source;

  bool get isEmpty => prices.isEmpty || maxTotal <= 0;

  factory ChipProfileData.fromJson(Map<String, dynamic> json) {
    List<double> f64List(dynamic v) {
      if (v is! List) return const [];
      return v.map((e) => (e as num).toDouble()).toList();
    }

    return ChipProfileData(
      profileId: json['profile_id']?.toString() ?? '',
      cutoffX: (json['cutoff_x'] as num?)?.toInt() ?? -1,
      bucketStep: (json['bucket_step'] as num?)?.toDouble() ?? 0.1,
      prices: f64List(json['prices']),
      s: f64List(json['s']),
      b: f64List(json['b']),
      total: f64List(json['total']),
      maxTotal: (json['max_total'] as num?)?.toDouble() ?? 0,
      source: json['source']?.toString() ?? 'rust',
    );
  }

  /// 局部峰索引（v >= 左邻 && v > 右邻，平顶峰取右端）。
  List<int> peakIndices() {
    final n = total.length;
    if (n == 0) return const [];
    final out = <int>[];
    for (var i = 0; i < n; i++) {
      final v = total[i];
      if (v <= 0) continue;
      final leftOk = i == 0 || v >= total[i - 1];
      final rightOk = i + 1 >= n || v > total[i + 1];
      if (leftOk && rightOk) out.add(i);
    }
    return out;
  }
}

/// 主图右侧筹码分布 + 峰延长线。
abstract final class ChipProfilePainter {
  /// [plotLeft]/[plotRight] 为 K 线主图区；筹码画在右侧 [paneWidth]。
  /// Y 与主图价格对齐：yOfPrice(price)。
  static void draw({
    required Canvas canvas,
    required ChipProfileData profile,
    required ChipConfig config,
    required double plotLeft,
    required double plotRight,
    required double plotTop,
    required double plotBottom,
    required double Function(double price) yOfPrice,
    int? highlightKn,
  }) {
    if (!config.enabled || profile.isEmpty) return;
    final paneW = math.max(24.0, config.paneWidth);
    final chipLeft = plotRight;
    final chipRight = plotRight + paneW;
    final midX = (chipLeft + chipRight) / 2;
    final halfW = (chipRight - chipLeft) / 2 - 2;
    if (halfW <= 1) return;

    // 拉伸：gamma = 1 / (1 + stretch*0.08)
    final stretch = config.stretchLevel.clamp(1, 20);
    final gamma = 1.0 / (1.0 + stretch * 0.08);
    final maxT = profile.maxTotal;

    final sPaint = Paint()..color = config.sColor;
    final bPaint = Paint()..color = config.bColor;

    for (var i = 0; i < profile.prices.length; i++) {
      final price = profile.prices[i];
      final y = yOfPrice(price);
      if (y < plotTop - 2 || y > plotBottom + 2) continue;
      final t = profile.total[i];
      if (t <= 0) continue;
      final ratio = math.pow(t / maxT, gamma).toDouble().clamp(0.0, 1.0);
      final barHalf = halfW * ratio;
      final halfStep = profile.bucketStep / 2;
      final bucketH = (yOfPrice(price - halfStep) - yOfPrice(price + halfStep)).abs().clamp(1.0, 60.0);
      final y0 = y - bucketH / 2;
      final y1 = y + bucketH / 2;
      final sv = i < profile.s.length ? profile.s[i] : 0.0;
      final bv = i < profile.b.length ? profile.b[i] : 0.0;
      final sum = sv + bv;
      if (sum <= 0) continue;
      // 左绿 S / 右红 B，按两侧占比分配半宽
      final sShare = sv / sum;
      final bShare = bv / sum;
      final sW = barHalf * (sShare * 2).clamp(0.0, 2.0);
      final bW = barHalf * (bShare * 2).clamp(0.0, 2.0);
      if (sW > 0.3) {
        canvas.drawRect(Rect.fromLTRB(midX - sW, y0, midX, y1), sPaint);
      }
      if (bW > 0.3) {
        canvas.drawRect(Rect.fromLTRB(midX, y0, midX + bW, y1), bPaint);
      }
    }

    // 分隔中轴
    canvas.drawLine(
      Offset(midX, plotTop),
      Offset(midX, plotBottom),
      Paint()
        ..color = const Color(0x33FFFFFF)
        ..strokeWidth = 0.8,
    );

    if (!config.peakLineEnabled) return;
    final peaks = profile.peakIndices();
    final linePaint = Paint()
      ..color = config.peakLineColor
      ..strokeWidth = config.peakLineWidth
      ..style = PaintingStyle.stroke;
    final dotPaint = Paint()..color = config.peakDotColor;
    for (final i in peaks) {
      final price = profile.prices[i];
      final y = yOfPrice(price);
      if (y < plotTop || y > plotBottom) continue;
      final from = Offset(plotLeft, y);
      final to = Offset(chipLeft, y);
      if (config.peakLineDashed) {
        _drawDashed(canvas, from, to, linePaint);
      } else {
        canvas.drawLine(from, to, linePaint);
      }
      canvas.drawCircle(Offset(chipLeft + 3, y), config.peakDotRadius, dotPaint);
    }

    // 层号小标（多 Kn 叠选时区分）
    if (highlightKn != null) {
      final tp = TextPainter(
        text: TextSpan(
          text: 'K$highlightKn',
          style: const TextStyle(
            color: Color(0xAAE5E7EB),
            fontSize: 9,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(chipLeft + 2, plotTop + 2));
    }
  }

  static void _drawDashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 5.0;
    const gap = 3.0;
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1) return;
    final ux = dx / len;
    final uy = dy / len;
    var t = 0.0;
    while (t < len) {
      final t2 = math.min(len, t + dash);
      canvas.drawLine(
        Offset(a.dx + ux * t, a.dy + uy * t),
        Offset(a.dx + ux * t2, a.dy + uy * t2),
        paint,
      );
      t += dash + gap;
    }
  }
}
