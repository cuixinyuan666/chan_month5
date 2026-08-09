/// ML 会话：图面使用权是否由机器学习工作台占用。
/// 不改 tip/步进生产逻辑；仅标志位交接。
class MlSessionController {
  bool _active = false;

  bool get isActive => _active;

  /// 进入 ML：占用 K 线图面使用权。
  void enter() {
    _active = true;
  }

  /// 退出 ML：归还图面给复盘 app。
  void exit() {
    _active = false;
  }
}
