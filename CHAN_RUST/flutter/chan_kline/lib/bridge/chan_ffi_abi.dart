/// 界面期望的动态库协议号。必须与 Rust `CHAN_FFI_ABI_VERSION` 相同。
/// 改管道 JSON / 冻结语义时两边一起加一，禁止静默混用旧库。
const int kChanFfiAbiVersion = 1;

/// 计算库缺失或版本对不上：界面停机，不继续算出另一套点。
class ChanFfiVersionException implements Exception {
  ChanFfiVersionException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 找不到库时的中文说明。
String chanFfiMissingLibraryMessage({
  required String triedPath,
  required Object cause,
}) {
  return '找不到缠论计算库。'
      '请把本次安装包（或本次编出来）的那一份覆盖到程序目录，'
      '开发时覆盖 windows/native/chan_ffi.dll，然后关掉软件再打开。'
      '不要混用旧备份。尝试路径：$triedPath。详情：$cause';
}

/// 旧库没有版本号。
String chanFfiMissingAbiSymbolMessage() {
  return '缠论计算库太旧，对不上当前界面（缺少版本号）。'
      '混用旧库会算出另一套买卖点/中枢。'
      '请用本次编出来的库覆盖 windows/native/chan_ffi.dll（安装包则覆盖 exe 旁边那一份），'
      '关掉软件再冷启动。';
}

/// 协议号对不上。
String chanFfiAbiMismatchMessage({required int got, required int expected}) {
  return '缠论计算库版本对不上：库是 $got，界面要 $expected。'
      '混用旧库会算出另一套买卖点/中枢。'
      '请用本次安装包里的那一份覆盖旧文件后冷启动，不要沿用 .bak。';
}
