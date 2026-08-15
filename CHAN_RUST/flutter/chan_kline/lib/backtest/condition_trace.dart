/// 条件求值链（Phase 12）。每一笔信号都能看见 AND/OR、取值、对象/关系编号。
class ConditionTrace {
  /// AND / OR / CMP / EXISTS / EQ …
  final String op;
  final bool? flag;
  final String label;
  final List<ConditionTrace> children;
  final String? variableId;
  final double? value;
  final String? objectId;
  final String? relationId;
  final bool unavailable;

  const ConditionTrace({
    required this.op,
    this.flag,
    required this.label,
    this.children = const [],
    this.variableId,
    this.value,
    this.objectId,
    this.relationId,
    this.unavailable = false,
  });

  String get text => _fmt(0);

  String _fmt(int depth) {
    final pad = '  ' * depth;
    final bits = <String>[label];
    if (unavailable) {
      bits.add('= 不可用');
    } else {
      if (value != null) bits.add('= ${_fmtNum(value!)}');
      if (flag != null) bits.add(flag! ? '= TRUE' : '= FALSE');
    }
    if (objectId != null) bits.add('objectId=$objectId');
    if (relationId != null) bits.add('relationId=$relationId');
    final line = '$pad${bits.join(' ')}';
    if (children.isEmpty) return line;
    return ([line, ...children.map((c) => c._fmt(depth + 1))]).join('\n');
  }
}

String _fmtNum(double v) {
  if (v == v.roundToDouble() && v.abs() >= 1) return v.toStringAsFixed(0);
  final s = v.toStringAsFixed(4);
  return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}
