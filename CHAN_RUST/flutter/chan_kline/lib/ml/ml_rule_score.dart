import '../models/bar_feature_lookup.dart';
import '../models/divergence_algo.dart';

/// tip 类别打分卡（-100..+100，正=偏多，负=偏空）。
class MlCategoryScore {
  const MlCategoryScore({
    required this.id,
    required this.title,
    required this.score,
    required this.weight,
    required this.explain,
    this.signals = const [],
  });

  final String id;
  final String title;
  /// -100..+100
  final double score;
  /// 合成总分权重（结构信号更大）
  final double weight;
  final String explain;
  final List<String> signals;

  double get weighted => score * weight;
}

/// 规则评分整包成果（教学向）。
class MlScoreReport {
  const MlScoreReport({
    required this.totalScore,
    required this.stance,
    required this.summary,
    required this.disclaimer,
    required this.categories,
    required this.asOfIdx,
    required this.barCount,
  });

  /// -100..+100
  final double totalScore;
  /// 偏多 / 偏空 / 观望
  final String stance;
  final String summary;
  final String disclaimer;
  final List<MlCategoryScore> categories;
  final int asOfIdx;
  final int barCount;

  List<String> get topSignals {
    final all = <String>[];
    for (final c in categories) {
      all.addAll(c.signals);
    }
    return all.take(8).toList();
  }
}

/// 对 tip 同源特征做规则评分（不训练、不省略类别）。
class MlRuleScore {
  MlRuleScore._();

  static const String disclaimer =
      '本结果为缠论特征规则演示，仅供学习理解结构信号，不构成任何投资建议。';

  /// 对 [lookup] 末根（或指定 asOf）打分。
  static MlScoreReport score(
    BarFeatureLookup lookup, {
    int? asOfIdx,
  }) {
    if (lookup.byIdx.isEmpty) {
      return const MlScoreReport(
        totalScore: 0,
        stance: '观望',
        summary: '尚无已喂入 K 线特征，无法打分。请确认设置里已选股票与区间。',
        disclaimer: disclaimer,
        categories: [],
        asOfIdx: -1,
        barCount: 0,
      );
    }
    final idxs = lookup.byIdx.keys.toList()..sort();
    final idx = asOfIdx ?? idxs.last;
    final row = lookup.byIdx[idx] ?? lookup.byIdx[idxs.last]!;
    final sub = row['sub'] is Map
        ? Map<String, dynamic>.from(row['sub'] as Map)
        : <String, dynamic>{};

    final maxKn = _inferMaxKn(sub, row);

    final cats = <MlCategoryScore>[
      _scoreVolumeTick(sub, maxKn),
      _scoreMergeFractal(row, sub, maxKn),
      _scoreZs(sub, maxKn),
      _scoreBs(sub, maxKn),
      _scoreDivergence(sub, maxKn),
      _scoreRatioRhythm(sub, maxKn),
      _scoreOtherMath(sub, maxKn),
      _scorePeaks(row, sub),
    ];

    var wSum = 0.0;
    var sSum = 0.0;
    for (final c in cats) {
      wSum += c.weight;
      sSum += c.weighted;
    }
    final total = wSum <= 0 ? 0.0 : (sSum / wSum).clamp(-100.0, 100.0);
    final stance = total >= 18
        ? '偏多'
        : total <= -18
            ? '偏空'
            : '观望';
    final summary = _buildSummary(stance, total, cats);

    return MlScoreReport(
      totalScore: double.parse(total.toStringAsFixed(1)),
      stance: stance,
      summary: summary,
      disclaimer: disclaimer,
      categories: cats,
      asOfIdx: idx,
      barCount: idxs.length,
    );
  }

  static int _inferMaxKn(Map<String, dynamic> sub, Map<String, dynamic> row) {
    var maxKn = 0;
    for (final k in sub.keys) {
      final m = RegExp(r'_(\d+)$').firstMatch(k);
      if (m != null) {
        final n = int.tryParse(m.group(1)!) ?? 0;
        if (n > maxKn) maxKn = n;
      }
    }
    final levels = row['levels'];
    if (levels is List) {
      for (final lv in levels) {
        // LevelSnap.level 为 structure；显示层可到 structure+1
        try {
          final lvNum = (lv as dynamic).level as int? ?? 0;
          if (lvNum + 1 > maxKn) maxKn = lvNum + 1;
        } catch (_) {}
      }
    }
    return maxKn.clamp(0, 12);
  }

  static MlCategoryScore _scoreVolumeTick(
    Map<String, dynamic> sub,
    int maxKn,
  ) {
    final signals = <String>[];
    var bias = 0.0;
    var hits = 0;
    for (var kn = 0; kn <= maxKn; kn++) {
      final b = _num(sub['buy_volume_$kn']);
      final s = _num(sub['sell_volume_$kn']);
      final g = _num(sub['gray_volume_$kn']);
      final t = b + s + g;
      if (t <= 0) continue;
      hits++;
      final net = (b - s) / t;
      bias += net * 40;
      if (net.abs() > 0.15) {
        signals.add(
          'K$kn成交量 B/S 净向=${net >= 0 ? "多" : "空"}'
          '(${(net * 100).toStringAsFixed(0)}%)',
        );
      }
      final tb = _num(sub['buy_tick_count_$kn']);
      final ts = _num(sub['sell_tick_count_$kn']);
      final tt = tb + ts + _num(sub['gray_tick_count_$kn']);
      if (tt > 0) {
        bias += ((tb - ts) / tt) * 20;
      }
    }
    final score = hits == 0 ? 0.0 : (bias / hits).clamp(-100.0, 100.0);
    return MlCategoryScore(
      id: 'volume_tick',
      title: '价量·笔数',
      score: _r1(score),
      weight: 0.08,
      explain: hits == 0
          ? '末根未见成交量/笔数三分解，记 0 分。'
          : '按各层买/卖/灰量与笔数净向打分（tip 同源 B/S/G）。',
      signals: signals.take(3).toList(),
    );
  }

  static MlCategoryScore _scoreMergeFractal(
    Map<String, dynamic> row,
    Map<String, dynamic> sub,
    int maxKn,
  ) {
    final signals = <String>[];
    var bias = 0.0;
    var hits = 0;
    // K0 确认
    final k0 = row['k0_confirm'];
    if (k0 is Map) {
      final v = (k0['value'] as num?)?.toInt() ?? 0;
      if (v == 1 || v == -1) {
        hits++;
        bias += v * 35;
        signals.add('K0分型确认=${v == 1 ? "底(+1)" : "顶(-1)"}');
      }
    }
    for (var kn = 0; kn <= maxKn; kn++) {
      final fx = sub['fractal_judgment_$kn'];
      if (fx == 'BOTTOM') {
        hits++;
        bias += 40;
        signals.add('K$kn分型判断=底');
      } else if (fx == 'TOP') {
        hits++;
        bias -= 40;
        signals.add('K$kn分型判断=顶');
      }
      final dist = _num(sub['fractal_peak_dist_$kn']);
      if (dist > 0) {
        // 距极点越近，结构越「新鲜」，略加强当前判断方向
        bias += (fx == 'BOTTOM' ? 1 : fx == 'TOP' ? -1 : 0) *
            (dist < 3 ? 8 : 3);
      }
    }
    final score = hits == 0 ? 0.0 : (bias / hits).clamp(-100.0, 100.0);
    return MlCategoryScore(
      id: 'merge_fractal',
      title: '合并·分型',
      score: _r1(score),
      weight: 0.12,
      explain: hits == 0
          ? '末根无分型确认/判断信号。'
          : '底分型偏多、顶分型偏空；含截断标记时仍按方向计。',
      signals: signals.take(4).toList(),
    );
  }

  static MlCategoryScore _scoreZs(Map<String, dynamic> sub, int maxKn) {
    final signals = <String>[];
    var bias = 0.0;
    var hits = 0;
    for (var kn = 0; kn <= maxKn; kn++) {
      final j = _num(sub['zs_judgment_$kn']);
      final c = _num(sub['zs_confirm_$kn']);
      if (j != 0) {
        hits++;
        // 判断值约定：与副图一致，非 0 表示有判断事件；方向弱化为结构活跃度
        bias += j > 0 ? 15 : -15;
        signals.add('K$kn中枢判断=$j');
      }
      if (c != 0) {
        hits++;
        bias += c > 0 ? 25 : -25;
        signals.add('K$kn中枢确认=$c');
      }
      final sure = _num(sub['zs_sure_$kn']);
      final hi = _num(sub['zs_high_$kn']);
      final lo = _num(sub['zs_low_$kn']);
      if (hi > 0 && lo > 0) {
        hits++;
        // 价格落在中枢相对位置需 close；此处仅记结构存在，小幅中性偏确认
        bias += sure > 0 ? 8 : 2;
        signals.add(
          'K$kn中枢区间 ${lo.toStringAsFixed(2)}~${hi.toStringAsFixed(2)}'
          '${sure > 0 ? "(确定)" : "(未确定)"}',
        );
      }
    }
    final score = hits == 0 ? 0.0 : (bias / hits).clamp(-100.0, 100.0);
    return MlCategoryScore(
      id: 'zs',
      title: '中枢',
      score: _r1(score),
      weight: 0.15,
      explain: hits == 0
          ? '末根未覆盖中枢读数。'
          : '中枢判断/确认与区间存在性参与打分（结构权重大）。',
      signals: signals.take(4).toList(),
    );
  }

  static MlCategoryScore _scoreBs(Map<String, dynamic> sub, int maxKn) {
    final signals = <String>[];
    var bias = 0.0;
    var hits = 0;
    for (var kn = 0; kn <= maxKn; kn++) {
      final b1 = sub['buy1_$kn'];
      final s1 = sub['sell1_$kn'];
      final b2 = sub['buy2_$kn'];
      final s2 = sub['sell2_$kn'];
      if (b1 != null && '$b1'.isNotEmpty && '$b1' != 'null') {
        hits++;
        bias += 70;
        signals.add('K$kn一类买 $b1');
      }
      if (s1 != null && '$s1'.isNotEmpty && '$s1' != 'null') {
        hits++;
        bias -= 70;
        signals.add('K$kn一类卖 $s1');
      }
      if (b2 != null && '$b2'.isNotEmpty && '$b2' != 'null') {
        hits++;
        bias += 45;
        signals.add('K$kn二类买 $b2');
      }
      if (s2 != null && '$s2'.isNotEmpty && '$s2' != 'null') {
        hits++;
        bias -= 45;
        signals.add('K$kn二类卖 $s2');
      }
      for (var cls = 3; cls <= 9; cls++) {
        final bn = sub['buyN_${kn}_$cls'];
        final sn = sub['sellN_${kn}_$cls'];
        if (bn != null && '$bn'.isNotEmpty && '$bn' != 'null') {
          hits++;
          bias += (40 - (cls - 3) * 3).clamp(20, 40).toDouble();
          signals.add('K$kn ${cls}类买 $bn');
        }
        if (sn != null && '$sn'.isNotEmpty && '$sn' != 'null') {
          hits++;
          bias -= (40 - (cls - 3) * 3).clamp(20, 40).toDouble();
          signals.add('K$kn ${cls}类卖 $sn');
        }
      }
    }
    final score = hits == 0 ? 0.0 : (bias / hits).clamp(-100.0, 100.0);
    return MlCategoryScore(
      id: 'bs',
      title: '买卖点',
      score: _r1(score),
      weight: 0.25,
      explain: hits == 0
          ? '末根无一类/二类/N类 BS 标签。'
          : '买点偏多、卖点偏空；一类权重大于二类/N类。',
      signals: signals.take(5).toList(),
    );
  }

  static MlCategoryScore _scoreDivergence(
    Map<String, dynamic> sub,
    int maxKn,
  ) {
    final signals = <String>[];
    var bias = 0.0;
    var hits = 0;
    for (var kn = 0; kn <= maxKn; kn++) {
      for (final algo in DivergenceAlgo.values) {
        final flag = sub[diverFeatureKey(algo, 'flag', kn)];
        if (flag == null) continue;
        final f = _num(flag);
        if (f == 0) continue;
        hits++;
        // flag>0 常见为卖背驰/顶背离偏空；<0 或买侧偏多——按符号
        bias += f > 0 ? -55 : 55;
        final ratio = sub[diverFeatureKey(algo, 'ratio', kn)];
        signals.add(
          'K$kn背驰_${algo.name} flag=$f'
          '${ratio != null ? " r=${_num(ratio).toStringAsFixed(2)}" : ""}',
        );
      }
    }
    final score = hits == 0 ? 0.0 : (bias / hits).clamp(-100.0, 100.0);
    return MlCategoryScore(
      id: 'divergence',
      title: '背驰',
      score: _r1(score),
      weight: 0.18,
      explain: hits == 0
          ? '末根无背驰 flag。'
          : '各算法背驰 flag 参与；结构权重仅次于买卖点。',
      signals: signals.take(5).toList(),
    );
  }

  static MlCategoryScore _scoreRatioRhythm(
    Map<String, dynamic> sub,
    int maxKn,
  ) {
    final signals = <String>[];
    var bias = 0.0;
    var hits = 0;
    for (var kn = 0; kn <= maxKn; kn++) {
      final ratio = sub['adjacent_ratio_$kn'];
      if (ratio is num) {
        hits++;
        final r = ratio.toDouble();
        // 比值>1 延伸加强原趋势不确定，贴近 1 记中性；>1.382 略偏动能
        if (r >= 1.382) {
          bias += 20;
          signals.add('K$kn比例=${r.toStringAsFixed(3)}(延伸偏强)');
        } else if (r > 0 && r < 0.618) {
          bias -= 10;
          signals.add('K$kn比例=${r.toStringAsFixed(3)}(收缩)');
        } else if (r > 0) {
          signals.add('K$kn比例=${r.toStringAsFixed(3)}');
        }
      }
      final lines = sub['step_rhythm_lines_$kn'];
      if (lines is List && lines.isNotEmpty) {
        hits++;
        // 节奏线存在=结构活跃，弱中性加分；读 label 不解析 tip 动态名作键
        bias += 8;
        final last = lines.last;
        if (last is Map) {
          final lab = last['label'] ?? last['name'];
          final val = last['value'];
          signals.add('K$kn节奏 $lab=${val ?? "-"}');
        } else {
          signals.add('K$kn节奏 ${lines.length}条');
        }
      } else {
        final one = sub['step_rhythm_$kn'];
        if (one != null) {
          hits++;
          bias += 5;
          signals.add('K$kn节奏=$one');
        }
      }
    }
    final score = hits == 0 ? 0.0 : (bias / hits).clamp(-100.0, 100.0);
    return MlCategoryScore(
      id: 'ratio_rhythm',
      title: '比例·节奏',
      score: _r1(score),
      weight: 0.10,
      explain: hits == 0
          ? '末根无相邻比例/步进节奏读数。'
          : '比例延伸与节奏线存在性参与；用底层固定键非 tip 动态名。',
      signals: signals.take(4).toList(),
    );
  }

  static MlCategoryScore _scoreOtherMath(
    Map<String, dynamic> sub,
    int maxKn,
  ) {
    final signals = <String>[];
    var bias = 0.0;
    var hits = 0;
    for (var kn = 0; kn <= maxKn; kn++) {
      final hist = sub['macd_hist_$kn'];
      if (hist is num) {
        hits++;
        bias += hist > 0 ? 25 : hist < 0 ? -25 : 0;
        signals.add('K$kn MACD柱=${hist.toStringAsFixed(4)}');
      }
      final rsi = sub['rsi_$kn'];
      if (rsi is num) {
        hits++;
        if (rsi >= 70) {
          bias -= 30;
          signals.add('K$kn RSI=${rsi.toStringAsFixed(1)}(偏高)');
        } else if (rsi <= 30) {
          bias += 30;
          signals.add('K$kn RSI=${rsi.toStringAsFixed(1)}(偏低)');
        } else {
          signals.add('K$kn RSI=${rsi.toStringAsFixed(1)}');
        }
      }
      final k = sub['kdj_k_$kn'];
      final d = sub['kdj_d_$kn'];
      if (k is num && d is num) {
        hits++;
        bias += (k - d) * 0.8;
        signals.add('K$kn KDJ K-D=${(k - d).toStringAsFixed(1)}');
      }
      final closeProxy = sub['boll_mid_$kn'];
      final up = sub['boll_up_$kn'];
      final down = sub['boll_down_$kn'];
      if (closeProxy is num && up is num && down is num && up > down) {
        // 无直接 close 时用 mid 距离估：带宽存在即记活跃
        hits++;
        bias += 2;
        signals.add('K$kn 布林带已就绪');
      }
      final slope = sub['line_slope_$kn'];
      if (slope is num) {
        hits++;
        bias += slope.clamp(-50, 50);
        signals.add('K$kn斜率=${slope.toStringAsFixed(4)}');
      }
      if (sub['demark_text_$kn'] != null) {
        hits++;
        final t = '${sub['demark_text_$kn']}';
        if (t.contains('买') || t.contains('完成买')) {
          bias += 35;
          signals.add('K$kn Demark $t');
        } else if (t.contains('卖') || t.contains('完成卖')) {
          bias -= 35;
          signals.add('K$kn Demark $t');
        } else if (t.isNotEmpty) {
          signals.add('K$kn Demark $t');
        }
      }
      if (sub['trend_support_price_$kn'] != null) {
        hits++;
        bias += 10;
        signals.add('K$kn趋势支撑=${sub['trend_support_price_$kn']}');
      }
      if (sub['trend_resist_price_$kn'] != null) {
        hits++;
        bias -= 10;
        signals.add('K$kn趋势压力=${sub['trend_resist_price_$kn']}');
      }
      if (sub['fx_triple_price_$kn'] != null) {
        hits++;
        signals.add('K$kn三型价=${sub['fx_triple_price_$kn']}');
      }
      if (sub['mean_text_$kn'] != null) {
        hits++;
        signals.add('K$kn均线 ${sub['mean_text_$kn']}');
      }
      if (sub['channel_text_$kn'] != null) {
        hits++;
        signals.add('K$kn通道 ${sub['channel_text_$kn']}');
      }
    }
    final score = hits == 0 ? 0.0 : (bias / hits).clamp(-100.0, 100.0);
    return MlCategoryScore(
      id: 'other_math',
      title: '其它指标(Math)',
      score: _r1(score),
      weight: 0.08,
      explain: hits == 0
          ? '末根无 MACD/RSI/KDJ/布林/斜率/Demark/趋势线等读数。'
          : 'Math 权重低于结构信号；多指标净向合成。',
      signals: signals.take(5).toList(),
    );
  }

  static MlCategoryScore _scorePeaks(
    Map<String, dynamic> row,
    Map<String, dynamic> sub,
  ) {
    final signals = <String>[];
    var bias = 0.0;
    var hits = 0;
    // 优先固定键；若无则从 metrics 感知筹码存在（不解析 tip 动态名）
    for (final key in ['chip_peaks', 'tick_peaks']) {
      final v = sub[key] ?? row[key];
      if (v is List && v.isNotEmpty) {
        hits++;
        bias += 5;
        signals.add('$key ${v.length}个');
      }
    }
    final metrics = row['metrics'];
    if (metrics is Map) {
      if (metrics['chip_tick_bins'] != null) {
        hits++;
        bias += 3;
        signals.add('metrics.chip_tick_bins 已就绪');
      }
      if (metrics['tick_count'] != null) {
        hits++;
        signals.add('metrics.tick_count=${metrics['tick_count']}');
      }
    }
    final score = hits == 0 ? 0.0 : (bias / hits).clamp(-100.0, 100.0);
    return MlCategoryScore(
      id: 'peaks',
      title: '筹码峰·笔数峰',
      score: _r1(score),
      weight: 0.04,
      explain: hits == 0
          ? '末根无峰/筹码底层数据（tip 动态名不参与键）。'
          : '峰与筹码底层存在性弱加权；方向中性偏结构完整度。',
      signals: signals.take(3).toList(),
    );
  }

  static String _buildSummary(
    String stance,
    double total,
    List<MlCategoryScore> cats,
  ) {
    final ranked = [...cats]..sort(
        (a, b) => b.score.abs().compareTo(a.score.abs()),
      );
    final top = ranked.take(2).map((e) => '${e.title}${e.score >= 0 ? "偏多" : "偏空"}').join('、');
    return '综合 $stance（总分 ${total.toStringAsFixed(1)}）。'
        '当前影响较大的类别：$top。'
        '建议先对照各类打分卡与 K 线小预览理解信号，再决定是否导出特征做进一步研究。';
  }

  static double _num(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0;
    return 0;
  }

  static double _r1(double v) => double.parse(v.toStringAsFixed(1));
}
