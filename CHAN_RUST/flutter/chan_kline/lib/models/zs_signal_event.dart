/// 中枢判断/确认副图事件（确认式打点；x=当步 K0，禁止整框回填）。
/// 稳定身份=层|x1；颗粒度键含 x（离开窗内可多点；单开放只首次）。
///
/// 重要：`dir`/`value` 存的是「上个中枢空间趋势」符号（抬高+1/下移-1），
/// **不是** Rust 框 `first.dir`；绘色走 ZsSignalColors，与分型顶蓝底红区分。
class ZsSignalEvent {
  /// 打点 K0 坐标（步进 discoveryX）
  final int x;
  /// 层号（与中枢同号：0=K0）
  final int kn;
  /// 本步 Rust seq（仅展示/排查；去重不用）
  final int seq;
  /// 中枢框左端（稳定身份；离开窗打点时仍用新候选 x1）
  final int x1;
  /// 空间趋势符号（与 value 同号；抬高>=0、下移<0）
  final int dir;
  /// 副图值：+1 升红 / -1 降绿（由空间趋势写入）
  final int value;

  const ZsSignalEvent({
    required this.x,
    required this.kn,
    required this.seq,
    required this.x1,
    required this.dir,
    required this.value,
  });
}
