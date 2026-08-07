/// 12+1 种背驰力度算法（前 12 对齐旧 `MACD_ALGO`；`lineSlope`=与 Kn连线斜率同源）。
enum DivergenceAlgo {
  area,
  peak,
  fullArea,
  diff,
  slope,
  amp,
  amount,
  volumn,
  amountAvg,
  volumnAvg,
  turnrateAvg,
  rsi,
  /// 与 Kn连线斜率同源：|(endVal-beginVal)/(endX-beginX)|
  lineSlope,
}

extension DivergenceAlgoMeta on DivergenceAlgo {
  /// 特征键 / 标签后缀（如 peak、full_area、斜率）
  String get key {
    switch (this) {
      case DivergenceAlgo.area:
        return 'area';
      case DivergenceAlgo.peak:
        return 'peak';
      case DivergenceAlgo.fullArea:
        return 'full_area';
      case DivergenceAlgo.diff:
        return 'diff';
      case DivergenceAlgo.slope:
        return 'slope';
      case DivergenceAlgo.amp:
        return 'amp';
      case DivergenceAlgo.amount:
        return 'amount';
      case DivergenceAlgo.volumn:
        return 'volumn';
      case DivergenceAlgo.amountAvg:
        return 'amount_avg';
      case DivergenceAlgo.volumnAvg:
        return 'volumn_avg';
      case DivergenceAlgo.turnrateAvg:
        return 'turnrate_avg';
      case DivergenceAlgo.rsi:
        return 'rsi';
      case DivergenceAlgo.lineSlope:
        return '斜率';
    }
  }

  static const List<DivergenceAlgo> all = DivergenceAlgo.values;
}

/// 依赖本层 MACD 柱的背驰算法（area/peak/full_area/diff）。
bool isMacdDivergenceAlgo(DivergenceAlgo? algo) {
  return algo == DivergenceAlgo.area ||
      algo == DivergenceAlgo.peak ||
      algo == DivergenceAlgo.fullArea ||
      algo == DivergenceAlgo.diff;
}

/// 特征键：diver_{algo}_{field}_{dkn}
String diverFeatureKey(DivergenceAlgo algo, String field, int displayKn) =>
    'diver_${algo.key}_${field}_$displayKn';
