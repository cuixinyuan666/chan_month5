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
    this.w = const [],
    this.source = 'rust',
  });

  final String profileId;
  final int cutoffX;
  final double bucketStep;
  final List<double> prices;
  final List<double> s;
  final List<double> b;
  /// 灰度（无方向分笔），total=s+b+w
  final List<double> w;
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
      w: f64List(json['w']),
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
    // 十字悬停的单根 B/S/灰度 量（区别于累计角标）
    ({double b, double s, double w})? hoverBar,
  }) {
    if (!config.enabled || profile.isEmpty) return;
    final paneW = math.max(24.0, config.paneWidth);
    final chipLeft = plotRight;
    final chipRight = plotRight + paneW;
    if (paneW <= 4) return;

    // 拉伸：gamma = 1 / (1 + stretch*0.08)
    final stretch = config.stretchLevel.clamp(1, 20);
    final gamma = 1.0 / (1.0 + stretch * 0.08);
    final maxT = profile.maxTotal;

    final sPaint = Paint()..color = config.sColor;
    final bPaint = Paint()..color = config.bColor;
    final wPaint = Paint()..color = config.wColor;

    for (var i = 0; i < profile.prices.length; i++) {
      final price = profile.prices[i];
      final y = yOfPrice(price);
      if (y < plotTop - 2 || y > plotBottom + 2) continue;
      final t = profile.total[i];
      if (t <= 0) continue;
      final ratio = math.pow(t / maxT, gamma).toDouble().clamp(0.0, 1.0);
      final barTotalW = (paneW - 4) * ratio;
      if (barTotalW <= 0.5) continue;
      final halfStep = profile.bucketStep / 2;
      final bucketH = (yOfPrice(price - halfStep) - yOfPrice(price + halfStep)).abs().clamp(1.0, 60.0);
      final y0 = y - bucketH / 2;
      final y1 = y + bucketH / 2;
      final sv = i < profile.s.length ? profile.s[i] : 0.0;
      final bv = i < profile.b.length ? profile.b[i] : 0.0;
      final wv = i < profile.w.length ? profile.w[i] : 0.0;
      final sum = sv + bv + wv;
      if (sum <= 0) continue;
      // 三段都从右向左：右 B 红 → 中 S 绿 → 左灰，右对齐
      // 踩坑：之前用 midX +/- 中心分裂方案，与 Rust chip profile draw 右对齐不一致；
      // 改为 chipRight 向右对齐后两侧水平柱视觉连续，不再有中间空隙。
      final bShare = bv / sum;
      final sShare = sv / sum;
      // 踩坑：clamp 上限不能为负（份额小时 barTotalW*share-0.3 < 0 会抛 ArgumentError）
      final bW = (barTotalW * bShare)
          .clamp(0.0, math.max(0.0, barTotalW - 0.3))
          .toDouble();
      final sW = (barTotalW * sShare)
          .clamp(0.0, math.max(0.0, barTotalW - bW - 0.3))
          .toDouble();
      final wW = math.max(0.0, barTotalW - bW - sW);
      // 红柱：从右边缘向左
      if (bW > 0.3) {
        canvas.drawRect(Rect.fromLTRB(chipRight - bW, y0, chipRight, y1), bPaint);
      }
      // 绿柱：接在红柱左侧向左
      if (sW > 0.3) {
        canvas.drawRect(Rect.fromLTRB(chipRight - bW - sW, y0, chipRight - bW, y1), sPaint);
      }
      // 灰柱：最左侧（无方向分笔）
      if (wW > 0.3) {
        canvas.drawRect(Rect.fromLTRB(chipRight - bW - sW - wW, y0, chipRight - bW - sW, y1), wPaint);
      }
    }

    // 右边缘竖线
    canvas.drawLine(
      Offset(chipRight - 1, plotTop),
      Offset(chipRight - 1, plotBottom),
      Paint()
        ..color = const Color(0x33FFFFFF)
        ..strokeWidth = 0.8,
    );

    // 右上角：B/S/灰度 累计角标（十字 as-of / 步进末根共用同一 profile 口径）
    _drawCornerSums(canvas, profile, chipLeft, chipRight, plotTop,
        config: config, hoverBar: hoverBar);

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

  /// 右上角 B/S/灰度 累计角标；文案过长（如日累计大数）拆两行，不压峰线。
  /// 十字悬停时另起一行高亮「当前」单根 B/S/灰 分布（分色，区别于累计）。
  static void _drawCornerSums(
    Canvas canvas,
    ChipProfileData profile,
    double chipLeft,
    double chipRight,
    double plotTop, {
    required ChipConfig config,
    ({double b, double s, double w})? hoverBar,
  }) {
    double sumOf(List<double> v) {
      var s = 0.0;
      for (final x in v) {
        s += x;
      }
      return s;
    }

    // 整数或去尾零；≥10万 显示万
    String fmt(double v) {
      if (!v.isFinite) return '0';
      if (v >= 100000) {
        final w = v / 10000;
        return '${_trimZeros(w)}万';
      }
      return (v - v.roundToDouble()).abs() < 1e-6
          ? v.round().toString()
          : _trimZeros(v);
    }

    final sumB = sumOf(profile.b);
    final sumS = sumOf(profile.s);
    final sumW = sumOf(profile.w);
    final full = 'B:${fmt(sumB)}, S:${fmt(sumS)}, 灰度:${fmt(sumW)}';
    final style = const TextStyle(color: Color(0x99FFFFFF), fontSize: 8);
    final avail = math.max(10.0, chipRight - chipLeft - 6);
    final xRight = chipRight - 3;
    var y = plotTop + 3;
    final tp = TextPainter(
      text: TextSpan(text: full, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    if (tp.width <= avail) {
      tp.paint(canvas, Offset(xRight - tp.width, y));
      y += tp.height + 2;
    } else {
      // 拆两行：第一行 B/S，第二行 灰度
      final row1 = 'B:${fmt(sumB)}, S:${fmt(sumS)}';
      final t1 = TextPainter(
        text: TextSpan(text: row1, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      final t2 = TextPainter(
        text: TextSpan(text: '灰度:${fmt(sumW)}', style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      t1.paint(canvas, Offset(xRight - t1.width, y));
      t2.paint(canvas, Offset(xRight - t2.width, y + t1.height + 2));
      y += t1.height + 2 + t2.height + 2;
    }

    if (hoverBar == null) return;
    // 悬停单根：分色高亮，区别于累计角标
    final dim = const TextStyle(color: Color(0x66FFFFFF), fontSize: 8);
    final valStyle = const TextStyle(fontSize: 8, fontWeight: FontWeight.w700);
    final hSpan = TextSpan(children: [
      TextSpan(text: '当前 ', style: dim),
      TextSpan(
        text: 'B:${fmt(hoverBar.b)}',
        style: valStyle.copyWith(color: config.bColor),
      ),
      TextSpan(text: ' ', style: dim),
      TextSpan(
        text: 'S:${fmt(hoverBar.s)}',
        style: valStyle.copyWith(color: config.sColor),
      ),
      TextSpan(text: ' ', style: dim),
      TextSpan(
        text: '灰:${fmt(hoverBar.w)}',
        style: valStyle.copyWith(color: config.wColor),
      ),
    ]);
    final ht = TextPainter(text: hSpan, textDirection: TextDirection.ltr)
      ..layout();
    ht.paint(canvas, Offset(xRight - ht.width, y));
  }

  static String _trimZeros(double v) {
    var s = v.toStringAsFixed(2);
    while (s.contains('.') && s.endsWith('0')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    return s;
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
