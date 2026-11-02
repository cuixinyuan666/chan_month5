import 'package:flutter/foundation.dart';

import '../models/kline_combine_bundle.dart';
import 'kline_viewport.dart';

/// 十字 as-of 查找缓存：同一帧内多窗共用一份。
///
/// 原本每个 [KlineChart] 各存一份 `_incAsOfByIdx`；分窗后 10 个窗会把同一段
/// asOf 前缀重算 10 遍（纯 CPU，但会被十字线逐像素移动放大）。抽出来共享后，
/// 同一 `(asOf, engine.gen)` 只算一次。
class AsOfLookupCache {
  int? asOf;
  int gen = -1;
  Map<int, Map<String, dynamic>>? byIdx;
  int totalLevels = 0;
  int maxBsClass = 9;

  bool matches(int targetAsOf, int targetGen) =>
      asOf == targetAsOf && gen == targetGen && byIdx != null;

  void clear() {
    asOf = null;
    gen = -1;
    byIdx = null;
    totalLevels = 0;
    maxBsClass = 9;
  }
}

/// 层级分窗联动控制器。
///
/// 口径（2026-11-02 用户确认）：
/// - 所有窗共用同一份 [viewport]（x 窗口 / y 缩放平移）与同一份主副比例：
///   只有几何完全一致，十字线才能「竖线同一列、横线同一行」；
/// - 只有含 K0 的窗可交互（`interactive: true`），它把十字线按
///   「K0 bar 下标 + 该像素对应价格」广播；其余窗只读，不注册键盘、不接手势；
/// - as-of 结构（中枢/合并/连线）全窗同源，禁止非 K0 窗看见末态未来数据。
class ChartSyncController extends ChangeNotifier {
  ChartSyncController({double mainFraction = kDefaultMainFraction})
      : _mainFraction = mainFraction;

  /// 主图占「主+副」区域比例的默认值（与单图口径一致）。
  static const double kDefaultMainFraction = 0.79;

  /// 全窗共享视口。可变对象：任何窗都不得再 new 第二份。
  final KlineViewport viewport = KlineViewport();

  /// 全窗共享的 as-of 查找缓存。
  final AsOfLookupCache asOfCache = AsOfLookupCache();

  /// 全窗共享的 as-of 中枢 bundle（sessionAsOfBundle 未命中历史时避免每窗都打 FFI）。
  int? zsAsOfKey;
  KlineCombineBundle? zsAsOfBundle;

  double _mainFraction;
  double get mainFraction => _mainFraction;

  /// 主/副分割比例变化：只有可交互窗能拖，其余窗被动跟随。
  void setMainFraction(double v) {
    if ((v - _mainFraction).abs() < 1e-6) return;
    _mainFraction = v;
    notifyListeners();
  }

  /// 副图顶部「副图指标胶囊条」占位高度。
  ///
  /// 只有可交互窗会真实挂那条胶囊条，被动窗没有；若各自按 0 去画，
  /// K0 窗的副图（如成交量）就会比其余窗矮一截，看着像两张图不是一套。
  /// 由可交互窗量完广播，被动窗照抄，保证副图内区高度全窗一致。
  double subChipBand = KlineViewport.subIndicatorChipBand;

  bool _crosshairOn = false;
  int? _crosshairBarIdx;
  double? _crosshairPrice;

  bool get crosshairOn => _crosshairOn;
  int? get crosshairBarIdx => _crosshairBarIdx;
  double? get crosshairPrice => _crosshairPrice;

  /// 视口（平移 / 缩放 / 步进）变更广播。
  ///
  /// 视口是共享可变对象，可交互窗平移时不经过 [publishCrosshair]；
  /// 被动窗必须被叫醒才会重画，否则会停在旧位置、与 K0 窗错位。
  void notifyViewportChanged() => notifyListeners();

  /// 可交互窗量到副图胶囊条高度后广播，让被动窗的副图内区与它同高。
  void setSubChipBand(double h) {
    if ((h - subChipBand).abs() < 0.5) return;
    subChipBand = h;
    notifyListeners();
  }

  /// 可交互窗广播十字线。`barIdx` 是 bars 下标（各窗共享同一份 bars），
  /// `price` 是该像素对应的价格（其余窗用 priceFromY 反算自己的 y）。
  void publishCrosshair({
    required bool on,
    int? barIdx,
    double? price,
  }) {
    final nextBarIdx = on ? barIdx : null;
    final nextPrice = on ? price : null;
    if (_crosshairOn == on &&
        _crosshairBarIdx == nextBarIdx &&
        _crosshairPrice == nextPrice) {
      return;
    }
    _crosshairOn = on;
    _crosshairBarIdx = nextBarIdx;
    _crosshairPrice = nextPrice;
    notifyListeners();
  }
}
