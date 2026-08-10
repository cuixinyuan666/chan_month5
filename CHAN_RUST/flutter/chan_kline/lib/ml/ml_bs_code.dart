/// BS 标签数值编码/解码（供 ML/特征工程用；tooltip 仍用原字符串）。
class MlBsCode {
  MlBsCode._();

  static final RegExp _re = RegExp(r'^(\d+)([BS])([a-z])$');

  /// 编码：方向×(类号×100 + 字母序)
  /// 示例： "1Ba" → 101, "2Sc" → -203
  static int encode(String? label) {
    if (label == null || label.isEmpty) return 0;
    final m = _re.firstMatch(label);
    if (m == null) return 0;
    final cls = int.parse(m.group(1)!);
    final side = m.group(2) == 'B' ? 1 : -1;
    final letter = m.group(3)!.codeUnitAt(0) - 'a'.codeUnitAt(0) + 1;
    // 防 0 与「无 BS」混淆
    if (cls < 1 || letter < 1) return 0;
    return side * (cls * 100 + letter);
  }

  /// 解码：101 → "1Ba", -203 → "2Sc"
  static String? decode(int code) {
    if (code == 0) return null;
    final sign = code > 0 ? 1 : -1;
    final abs = code * sign;
    final cls = abs ~/ 100;
    final letter = abs % 100;
    if (cls < 1 || letter < 1) return null;
    final side = sign > 0 ? 'B' : 'S';
    final letterChar = String.fromCharCode('a'.codeUnitAt(0) + letter - 1);
    return '$cls$side$letterChar';
  }
}
