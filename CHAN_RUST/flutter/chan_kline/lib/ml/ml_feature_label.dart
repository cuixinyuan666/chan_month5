/// 英文特征键 → 中文可读名映射。
class MlFeatureLabel {
  MlFeatureLabel._();

  static String toChinese(String key) {
    // 筹码分箱
    if (key.startsWith('metrics.chip_tick_bins.')) {
      final parts = key.split('.');
      if (parts.length >= 3) {
        final dim = parts[1];
        final idx = parts[2];
        switch (dim) {
          case 's':
            return '筹码买量($idx)';
          case 'b':
            return '筹码卖量($idx)';
          case 'p':
            return '筹码价格($idx)';
          default:
            return '筹码$dim($idx)';
        }
      }
      return key;
    }
    // 背驰：diver_{algo}_{field}_{kn}（algo 可含下划线：full_area / line_slope）
    if (key.contains('diver_')) {
      final idx = key.indexOf('diver_') + 6;
      final rest = key.substring(idx);
      final m = RegExp(r'^(.*)_(in|out|ratio|flag)_(\d+)$').firstMatch(rest);
      if (m != null) {
        final algo = m.group(1)!;
        final field = m.group(2)!;
        final kn = m.group(3)!;
        return 'K$kn 背驰${_algoName(algo)}${_fieldName(field)}';
      }
      return key;
    }
    // KDJ
    if (key.startsWith('sub.kdj_')) {
      final parts = key.split('_');
      if (parts.length >= 3) {
        final kn = parts[2];
        final metric = parts[1];
        return 'K$kn KDJ-$metric';
      }
      return key;
    }
    // RSI
    if (key.startsWith('sub.rsi_')) {
      final kn = key.split('_').last;
      return 'K$kn RSI';
    }
    // 分型极点距
    if (key.startsWith('sub.fractal_peak_dist')) {
      if (key == 'sub.fractal_peak_dist') return '分型极点距(通用)';
      final kn = key.split('_').last;
      return 'K$kn 分型极点距';
    }
    // 分型判断
    if (key.startsWith('sub.fractal_judgment')) {
      if (key.endsWith('_trunc')) return 'K0 截断分型判断';
      final kn = key.split('_').last.replaceAll('_trunc', '');
      return 'K$kn 分型判断';
    }
    // 中枢
    if (key.startsWith('sub.zs_')) {
      final parts = key.split('_');
      final kn = parts[2];
      final metric = parts[1];
      switch (metric) {
        case 'high':
          return 'K$kn 中枢高';
        case 'low':
          return 'K$kn 中枢低';
        case 'sure':
          return 'K$kn 中枢已确认';
        case 'seq':
          return 'K$kn 中枢序号';
        default:
          return 'K$kn 中枢$metric';
      }
    }
    // 买卖点：*_code 数值编码优先于字符串序列
    if (key.contains('buy1_') || key.contains('sell1_') ||
        key.contains('buy2_') || key.contains('sell2_') ||
        key.contains('buyN_') || key.contains('sellN_')) {
      final isCode = key.endsWith('_code');
      String side;
      String clsName;
      if (key.contains('buy1_') || key.contains('sell1_')) {
        side = key.contains('buy1_') ? '买' : '卖';
        clsName = '一类';
      } else if (key.contains('buy2_') || key.contains('sell2_')) {
        side = key.contains('buy2_') ? '买' : '卖';
        clsName = '二类';
      } else {
        side = key.contains('buyN_') ? '买' : '卖';
        // buyN_0_3_code → 三类
        final parts = key.split('_');
        final clsPart = parts.length >= 3 ? parts[2] : '?';
        clsName = '$clsPart类';
      }
      final knMatch = RegExp(r'_(\d+)(?:_code)?$').firstMatch(key);
      final kn = knMatch?.group(1) ?? '?';
      if (isCode) {
        // N类键形如 buyN_0_3_code，层号在倒数第三段
        if (key.contains('buyN_') || key.contains('sellN_')) {
          final p = key.split('_');
          final knN = p.length >= 3 ? p[1] : kn;
          final clsN = p.length >= 3 ? p[2] : '?';
          return 'K$knN ${clsN}类$side编码';
        }
        return 'K$kn $clsName$side编码';
      }
      return 'K$kn $clsName$side点序列';
    }
    // 节奏 labelInt / dirInt
    if (key.contains('step_rhythm_lines_')) {
      final m = RegExp(r'step_rhythm_lines_(\d+)').firstMatch(key);
      final kn = m?.group(1) ?? '?';
      if (key.endsWith('.labelInt')) return 'K$kn 节奏名编码';
      if (key.endsWith('.dirInt')) return 'K$kn 节奏方向';
      if (key.endsWith('.value')) return 'K$kn 节奏投影价';
      if (key.endsWith('.ratio')) return 'K$kn 节奏比值';
    }
    // Demark 结构化
    if (key.contains('demark_marks_')) {
      final m = RegExp(r'demark_marks_(\d+)').firstMatch(key);
      final kn = m?.group(1) ?? '?';
      if (key.endsWith('.type')) return 'K$kn Demark类型';
      if (key.endsWith('.dir')) return 'K$kn Demark方向';
      if (key.endsWith('.idx')) return 'K$kn Demark序号';
      return 'K$kn Demark标记';
    }
    // 成交量/笔数
    if (key.startsWith('sub.volume_')) {
      final kn = key.split('_').last;
      return 'K$kn 成交量';
    }
    if (key.startsWith('sub.buy_volume_') || key.startsWith('sub.sell_volume_') ||
        key.startsWith('sub.gray_volume_')) {
      final prefix = key.startsWith('sub.buy_volume_') ? '买' :
                     key.startsWith('sub.sell_volume_') ? '卖' : '灰';
      final kn = key.split('_').last;
      return 'K$kn $prefix量';
    }
    if (key.startsWith('sub.gray_tick_count_') ||
        key.startsWith('sub.buy_tick_count_') ||
        key.startsWith('sub.sell_tick_count_')) {
      final prefix = key.startsWith('sub.buy_tick_count_') ? '买' :
                     key.startsWith('sub.sell_tick_count_') ? '卖' : '灰';
      final kn = key.split('_').last;
      return 'K$kn $prefix笔数';
    }
    // K1 快照字段
    if (key.startsWith('k1_snapshot.')) {
      final field = key.split('.').last;
      switch (field) {
        case 'building_seg_dir':
          return 'K1 构建段方向';
        case 'first_seg_dir':
          return 'K1 首段方向';
        case 'k1_confirm':
          return 'K1 确认信号';
        default:
          return 'K1 $field';
      }
    }
    if (key == 'k1_merge_count') return 'K1 合并计数';
    if (key == 'k1_merge_inner_seq') return 'K1 合并内序号';
    // 合并框
    if (key == 'combine.in_merge') return '合并框内合并';
    if (key == 'combine_range_high_2') return 'K2 合并区间高';
    if (key == 'combine_range_low_2') return 'K2 合并区间低';
    // 三型/四型价
    if (key == 'sub.fx_triple_price_0') return 'K0 三型价';
    if (key == 'sub.fx_triple_price_1') return 'K1 三型价';
    if (key == 'sub.fx_quad_top_price_1') return 'K1 四型顶价';
    // 趋势线
    if (key == 'sub.trend_support_price_0') return 'K0 趋势支撑';
    if (key == 'sub.trend_resist_price_1') return 'K1 趋势阻力';
    // 通道
    if (key == 'sub.channel_min_0_20') return 'K0 通道下界(20)';
    if (key == 'sub.channel_max_2_20') return 'K2 通道上界(20)';
    if (key == 'sub.channel_max_2_60') return 'K2 通道上界(60)';
    // K0 确认
    if (key == 'sub.k0_confirm_value') return 'K0 确认值';
    if (key == 'sub.k0_confirm_truncated') return 'K0 截断确认';
    // 默认：返回原键
    return key;
  }

  static String _algoName(String algo) {
    switch (algo) {
      case 'area': return '面积';
      case 'peak': return '极值';
      case 'full_area': return '全面积';
      case 'diff': return '差值';
      case 'slope': return '振幅摊平';
      case 'amp': return '振幅';
      case 'amount': return '成交额';
      case 'volumn': return '成交量';
      case 'amount_avg': return '均额';
      case 'volumn_avg': return '均量';
      case 'rsi': return 'RSI';
      case 'line_slope': return '连线斜率';
      case '斜率': return '连线斜率';
      default: return '($algo)';
    }
  }

  static String _fieldName(String field) {
    switch (field) {
      case 'in': return ' 进量';
      case 'out': return ' 出量';
      case 'ratio': return ' 比值';
      case 'flag': return ' 标志位';
      case 'avg': return ' 均值';
      case 'value': return ' 值';
      default: return ' $field';
    }
  }
}
