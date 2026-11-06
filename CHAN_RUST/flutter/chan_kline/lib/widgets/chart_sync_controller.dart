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

/// 十字线接管前的视口快照：关掉十字线时原样还回去。
///
/// 只记「怎么看」（x 窗口 / y 缩放与平移），不记 `allXMax` 这类数据边界：
/// 接管期间如果又步进了新 K，边界必须跟着数据走，不能被旧快照倒推回去。
class _ViewportSnapshot {
  _ViewportSnapshot.of(KlineViewport v)
      : viewXMin = v.viewXMin,
        viewXMax = v.viewXMax,
        yZoomRatio = v.yZoomRatio,
        yShiftRatio = v.yShiftRatio,
        ready = v.ready,
        userAdjustedView = v.userAdjustedView;

  final double viewXMin;
  final double viewXMax;
  final double yZoomRatio;
  final double yShiftRatio;
  final bool ready;
  final bool userAdjustedView;

  void applyTo(KlineViewport v) {
    v.viewXMin = viewXMin;
    v.viewXMax = viewXMax;
    v.yZoomRatio = yZoomRatio;
    v.yShiftRatio = yShiftRatio;
    v.ready = ready;
    v.userAdjustedView = userAdjustedView;
  }
}

/// 层级分窗联动控制器（第二版口径，2026-11-02 用户确认）。
///
/// - 每窗各自一份 [KlineViewport]：放大/缩小/平移互不牵连；
/// - 主副比例仍全窗共用一份：拖任一窗分割线，所有窗几何一起变；
/// - 十字线：任一窗都能开启。开启瞬间，该窗成为「主窗」，其余窗的视口
///   临时切到主窗同一段（同一根 K 同一列、同一价格同一行）；关闭后，
///   其余窗恢复各自开启前的缩放/位置；
/// - 十字线开启期间，若某窗视窗里看不到十字线那根 K，该窗自己平移把它带进可见区
///   （只平移、不改缩放，见 `KlineChart._applySyncedCrosshair`）；
/// - as-of 结构（中枢/合并/连线）全窗同源，禁止非主窗看见末态未来数据。
class ChartSyncController extends ChangeNotifier {
  ChartSyncController({double mainFraction = kDefaultMainFraction})
      : _mainFraction = mainFraction;

  /// 主图占「主+副」区域比例的默认值（与单图口径一致）。
  static const double kDefaultMainFraction = 0.79;

  /// 每层一份视口。层级在分窗里不会重复占用，故用层号作键。
  final Map<int, KlineViewport> _viewports = <int, KlineViewport>{};

  /// 取某层视口；没有就现建一份（重建同层时沿用原缩放）。
  KlineViewport viewportFor(int level) =>
      _viewports.putIfAbsent(level, () => KlineViewport());

  /// 全窗共享的 as-of 查找缓存。
  final AsOfLookupCache asOfCache = AsOfLookupCache();

  /// 全窗共享的 as-of 中枢 bundle（sessionAsOfBundle 未命中历史时避免每窗都打 FFI）。
  int? zsAsOfKey;
  KlineCombineBundle? zsAsOfBundle;

  double _mainFraction;
  double get mainFraction => _mainFraction;

  /// 主/副分割比例变化：任一窗都能拖，其余窗跟着变。
  void setMainFraction(double v) {
    if ((v - _mainFraction).abs() < 1e-6) return;
    _mainFraction = v;
    notifyListeners();
  }

  /// 副图顶部「副图指标胶囊条」占位高度。
  ///
  /// 各窗副图内区必须同高：有胶囊条的窗量完上报，其余窗照抄。
  /// 取「历史最大值」而不是最后一次写入：不同层胶囊条换行数不同，
  /// 互相覆盖会让各窗高度来回跳，反而更不对齐。
  double subChipBand = KlineViewport.subIndicatorChipBand;

  bool _crosshairOn = false;
  int? _crosshairBarIdx;
  double? _crosshairPrice;
  int? _crosshairOwnerLevel;

  /// 十字信息是否打开（第二次滚轮单击）。
  /// 各窗只看这一份：鼠标进到哪个窗，信息就由那个窗算、那个窗显示。
  bool _crosshairTooltip = false;

  /// 每次「十字线开启 / 换主窗」自增；窗用它判断要不要重新接管视口。
  int _crosshairTakeoverSeq = 0;

  /// 开启前各窗视口快照：关闭时还原。
  final Map<int, _ViewportSnapshot> _savedViewports = {};

  /// 主窗上次被抄走的视口签名：十字线开着时主窗缩放/平移，其余窗要继续跟。
  String? _ownerViewportSig;

  bool get crosshairOn => _crosshairOn;
  int? get crosshairBarIdx => _crosshairBarIdx;
  double? get crosshairPrice => _crosshairPrice;
  int? get crosshairOwnerLevel => _crosshairOwnerLevel;
  bool get crosshairTooltip => _crosshairTooltip;
  int get crosshairTakeoverSeq => _crosshairTakeoverSeq;

  /// 副图胶囊条高度上报（只增不减）；超过上限按上限算。
  void setSubChipBand(double h) {
    final next = h.clamp(
      KlineViewport.subIndicatorChipBand,
      KlineViewport.subIndicatorChipMaxBand,
    );
    if (next <= subChipBand + 0.5) return;
    subChipBand = next;
    notifyListeners();
  }

  /// 窗口数量/层级变了，胶囊条占位重新从默认值量起。
  void resetSubChipBand() {
    if ((subChipBand - KlineViewport.subIndicatorChipBand).abs() < 0.5) return;
    subChipBand = KlineViewport.subIndicatorChipBand;
    notifyListeners();
  }

  /// 广播十字线。`barIdx` 是 bars 下标（各窗共享同一份 bars），
  /// `price` 是该像素对应的价格（其余窗用自己的价格区间反算 y）。
  ///
  /// [ownerLevel] 为驱动十字线的窗（鼠标当前所在的那一格）。开启或换主窗时
  /// 会把其余窗视口切到主窗同一段；关闭时还原各窗各自的视口。
  /// [tooltip] 为十字信息是否打开：鼠标跨窗后信息跟着新主窗走。
  void publishCrosshair({
    required bool on,
    int? barIdx,
    double? price,
    int? ownerLevel,
    bool tooltip = false,
  }) {
    if (!on) {
      final changed = _crosshairOn || _crosshairBarIdx != null || _crosshairTooltip;
      _crosshairOn = false;
      _crosshairBarIdx = null;
      _crosshairPrice = null;
      _crosshairOwnerLevel = null;
      _crosshairTooltip = false;
      _ownerViewportSig = null;
      _restoreViewports();
      if (changed) notifyListeners();
      return;
    }

    final owner = ownerLevel;
    final wasOn = _crosshairOn;
    final ownerChanged = owner != null && owner != _crosshairOwnerLevel;
    final tooltipChanged = _crosshairTooltip != tooltip;
    final contentChanged =
        !wasOn || _crosshairBarIdx != barIdx || _crosshairPrice != price;

    _crosshairOn = true;
    _crosshairBarIdx = barIdx;
    _crosshairPrice = price;
    _crosshairTooltip = tooltip;

    var viewportChanged = false;
    if (owner != null && (!wasOn || ownerChanged)) {
      _crosshairOwnerLevel = owner;
      if (!wasOn) _captureViewports();
      _takeOverViewport(owner);
      _ownerViewportSig = _viewportSignature(owner);
      _crosshairTakeoverSeq++;
    } else if (owner != null) {
      _crosshairOwnerLevel = owner;
      // 十字线开着时主窗又缩放/平移：其余窗继续跟随，否则竖线/横线会错位。
      final sig = _viewportSignature(owner);
      if (sig != _ownerViewportSig) {
        _ownerViewportSig = sig;
        _takeOverViewport(owner);
        viewportChanged = true;
      }
    }

    if (contentChanged ||
        tooltipChanged ||
        viewportChanged ||
        !wasOn ||
        ownerChanged) {
      notifyListeners();
    }
  }

  String _viewportSignature(int level) {
    final v = _viewports[level];
    if (v == null) return '';
    return '${v.viewXMin}/${v.viewXMax}/${v.yZoomRatio}/${v.yShiftRatio}';
  }

  /// 开十字线前记下各窗各自的视口（含主窗）。
  ///
  /// 主窗也要记：十字线开着时若用户改到别的窗操作（主窗换手），原主窗会被
  /// 接管成新主窗的视口，关闭时必须能还回它自己开十字线前的位置。
  void _captureViewports() {
    _savedViewports.clear();
    for (final e in _viewports.entries) {
      _savedViewports[e.key] = _ViewportSnapshot.of(e.value);
    }
  }

  /// 把主窗的视口抄给其余窗：同一根 K 同一列、同一价格同一行。
  void _takeOverViewport(int owner) {
    final src = _viewports[owner];
    if (src == null) return;
    final snap = _ViewportSnapshot.of(src);
    for (final e in _viewports.entries) {
      if (e.key == owner) continue;
      snap.applyTo(e.value);
    }
  }

  /// 关十字线：各窗回到开启前自己的缩放/位置。
  void _restoreViewports() {
    if (_savedViewports.isEmpty) return;
    for (final e in _savedViewports.entries) {
      final vp = _viewports[e.key];
      if (vp != null) e.value.applyTo(vp);
    }
    _savedViewports.clear();
  }
}
