import 'equity_curve.dart';

String formatMoney(double v, {int digits = 2}) => v.toStringAsFixed(digits);

String formatPctFraction(MetricNum m) {
  if (m.isInfinity) return '∞';
  if (m.isUnavailable) return '不可用';
  return '${((m.value ?? 0) * 100).toStringAsFixed(2)}%';
}

String formatMetricNum(MetricNum m, {int digits = 4}) {
  if (m.isInfinity) return '∞';
  if (m.isUnavailable) return '不可用';
  return (m.value ?? 0).toStringAsFixed(digits);
}
