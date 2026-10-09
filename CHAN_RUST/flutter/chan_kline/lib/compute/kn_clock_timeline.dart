import '../models/level_models.dart';

/// K1+ 采样钟的「当时快照」时间线（动态段口径 / 当下性）。
///
/// **为什么需要它**：K1 及以上的穿越/事件条件按「虚拟 K 样本」取样，而样本点落在哪根 K，
/// 取决于**当时那一层走到哪了**。若事后用最终态的段划分来采样，「当时正在生长、还没定型」
/// 的那一段会被划到别处，asOf 那一刻就没有采样点，动态段中途成立的信号因此丢失或被推迟到段尾。
///
/// 本时间线在步进重放时**每一步**记下「这一步新确认了哪些段」+「这一步正在生长的是哪一段」，
/// 求值时按 asOf 还原当时的段划分，从而与实盘当时真正能看到的一致。
///
/// **按层分轨（2026-10-09 修）**：displayKn 的采样父层是 `level == displayKn - 1`
/// （与最终态口径 `bundleAtLevel(levels, displayKn - 1)` 一致）。此前本时间线**只记 level 0**，
/// 于是 `collectKnOhlcSamplesAt` 对 K2 及以上一律返回 level0 的采样点 ——
/// `RAW.K2.CLOSE` 拿到的是 K1 的收盘，违反「全层同构」。现在每层各记一条轨。
///
/// **只存增量**：每步每层大约记 0~1 个新确认段 + 1 个动态段，内存与步数×层数成正比
/// （不与段数平方成正比）。
class KnClockLevelStep {
  /// 本层本步新确认（定型）的段。
  final List<LevelUnitBar> newlyConfirmed;

  /// 本层本步正在生长、尚未定型的那一段（离开则为 null）。
  final LevelUnitBar? activeUnit;

  const KnClockLevelStep({required this.newlyConfirmed, required this.activeUnit});
}

/// 某一层在 asOf 当时的段划分还原结果。
typedef KnClockState = ({List<LevelUnitBar> unitBars, LevelUnitBar? activeUnit});

class KnClockTimeline {
  /// 记录步序（升序）。步进是连续递增的，用数组即可；查最近一步走二分。
  final List<int> _asOfKeys = <int>[];

  /// layer → 该层每一步的快照（索引与 [_asOfKeys] 一一对应）。
  final Map<int, List<KnClockLevelStep>> _stepsByLevel = <int, List<KnClockLevelStep>>{};

  final Map<(int, int?), KnClockState> _cache = <(int, int?), KnClockState>{};
  final Map<(int, int?), List<int>> _sampleEndsCache = <(int, int?), List<int>>{};

  bool get isEmpty => _asOfKeys.isEmpty;

  /// 已记录过快照的层号（升序）。
  List<int> get levels => _stepsByLevel.keys.toList()..sort();

  /// 清空（换标的 / 重来 / 步退到根）。
  void clear() {
    _asOfKeys.clear();
    _stepsByLevel.clear();
    _cache.clear();
    _sampleEndsCache.clear();
  }

  /// 已记录的步数。
  int get length => _asOfKeys.length;

  /// 最后记录的 asOf（空时为 -1）。
  int get lastAsOf => _asOfKeys.isEmpty ? -1 : _asOfKeys.last;

  /// 记一步。重复 asOf 会被忽略（步进每根 K 只记一次）。
  ///
  /// [byLevel] 的 key 是采样父层 level（= displayKn - 1）；某层本步不存在就整层不出现在
  /// map 里（等价于「该层当刻没有已确认段也没有动态段」）。
  void record(int asOf, Map<int, KnClockLevelStep> byLevel) {
    if (_asOfKeys.isNotEmpty && _asOfKeys.last == asOf) return;
    _asOfKeys.add(asOf);
    for (final e in byLevel.entries) {
      final steps = _stepsByLevel.putIfAbsent(e.key, () => <KnClockLevelStep>[]);
      // 某层可能晚于其它层才出现；补齐它缺席的早期步（空快照 = 当刻该层无段）。
      while (steps.length < _asOfKeys.length - 1) {
        steps.add(const KnClockLevelStep(newlyConfirmed: [], activeUnit: null));
      }
      steps.add(e.value);
    }
    _cache.clear();
    _sampleEndsCache.clear();
  }

  /// 还原 asOf 当时 [level] 层的段划分：[asOf] 为 null 表示最后一步。
  ///
  /// 累计 asOf 之前（含）各步新确认的段，并取那一步的动态段。
  KnClockState at(int level, int? asOf) {
    final cached = _cache[(level, asOf)];
    if (cached != null) return cached;
    final steps = _stepsByLevel[level];
    if (steps == null || steps.isEmpty || _asOfKeys.isEmpty) {
      return _cache[(level, asOf)] =
          (unitBars: const <LevelUnitBar>[], activeUnit: null);
    }
    // 找 <= asOf 的最后一步（asOf 为 null 取最后一步）
    var hi = _asOfKeys.length;
    var stepIndex = steps.length;
    if (asOf != null) {
      var lo = 0;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (_asOfKeys[mid] <= asOf) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      stepIndex = lo;
      if (lo == 0) {
        // asOf 早于第一次记录：当时什么都还没有
        return _cache[(level, asOf)] =
            (unitBars: const <LevelUnitBar>[], activeUnit: null);
      }
    }
    final last = stepIndex - 1;
    final unitBars = <LevelUnitBar>[];
    for (var i = 0; i <= last; i++) {
      unitBars.addAll(steps[i].newlyConfirmed);
    }
    unitBars.sort((a, b) => a.x2.compareTo(b.x2));
    return _cache[(level, asOf)] =
        (unitBars: unitBars, activeUnit: steps[last].activeUnit);
  }

  /// 指纹（供前缀重放对拍比对）：覆盖**所有层**，少一层就等于漏盯一块。
  String signature(int? asOf) {
    final parts = <String>[];
    for (final lv in levels) {
      final s = at(lv, asOf);
      final conf = s.unitBars
          .map((u) => '${u.x1}-${u.x2}d${u.dir}')
          .join(',');
      final a = s.activeUnit;
      parts.add('L$lv[$conf|act=${a == null ? '-' : '${a.x1}-${a.x2}d${a.dir}@${a.close}'}]');
    }
    return parts.join(';');
  }

  // ---------------------------------------------------------------------
  // 逐 bar 采样点（K1+ 穿越判定的正确口径 / 当下性）
  //
  // 上一段「一段一个采样点」的做法只对 asOf=末根成立：一次性判全区间时，
  // 「第 x 根那里有一个采样点」这件事只有走到 x 才知道，单点求值永远拿不到。
  // 实盘是**每根 K 都在场判一次**，所以采样点必须是：
  //   所有 x ≤ asOf 且「x 那一刻 [level] 层存在正在生长的段（dir≠0）」的 bar。
  // 段定型那一根也算（那一刻它就是 active 段末端），因此已确认段的右端天然被覆盖。
  // ---------------------------------------------------------------------

  /// 逐 bar 采样点右端（升序、去重）。结果按 (level, asOf) 缓存。
  List<int> sampleEnds(int level, int? asOf) {
    final cached = _sampleEndsCache[(level, asOf)];
    if (cached != null) return cached;
    final steps = _stepsByLevel[level];
    if (steps == null || steps.isEmpty) {
      return _sampleEndsCache[(level, asOf)] = const <int>[];
    }
    final limit = asOf ?? _asOfKeys.last;
    final seen = <int>{};
    final out = <int>[];
    for (var i = 0; i < _asOfKeys.length && i < steps.length; i++) {
      if (_asOfKeys[i] > limit) break;
      final a = steps[i].activeUnit;
      if (a == null || (a.dir != 1 && a.dir != -1) || a.x2 < 0) continue;
      if (a.x1 > _asOfKeys[i]) continue;
      if (seen.add(_asOfKeys[i])) out.add(_asOfKeys[i]);
    }
    out.sort();
    return _sampleEndsCache[(level, asOf)] = out;
  }

  /// x 那一刻 [level] 层动态段的 OHLC（x 必须是该层的采样点）。
  ({double open, double high, double low, double close})? activeOhlcAt(
    int level,
    int x,
  ) {
    final i = _indexOfAsOf(x);
    if (i < 0) return null;
    final steps = _stepsByLevel[level];
    if (steps == null || i >= steps.length) return null;
    final a = steps[i].activeUnit;
    if (a == null || (a.dir != 1 && a.dir != -1) || a.x2 < 0) return null;
    return (open: a.open, high: a.high, low: a.low, close: a.close);
  }

  int _indexOfAsOf(int x) {
    var lo = 0;
    var hi = _asOfKeys.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_asOfKeys[mid] < x) {
        lo = mid + 1;
      } else if (_asOfKeys[mid] > x) {
        hi = mid;
      } else {
        return mid;
      }
    }
    return -1;
  }
}

/// 采样钟退场诊断（防止「静默退回冻段口径」再次无声发生）。
///
/// 背景：K1+ 采样点取不到时，`catalog_lookup` 会退回最终态段划分（冻段口径）。
/// 这条退化**不崩、不报错、测试全绿**，只是把信号推到段尾 —— `error remember.md`
/// 第 11 条记的就是它。因此这里做两个静态计数器：任一非零就说明有路径退化过，
/// 回归测试可断言它为 0。
class KnClockDiagnostics {
  KnClockDiagnostics._();

  /// 传了 knClock 但它是空的（时间线没记上）→ 退回最终态。
  static int emptyTimelineFallbacks = 0;

  /// 压根没传 knClock → 退回最终态（绘图/诊断属正常，求值链出现即为退化）。
  static int missingTimelineFallbacks = 0;

  /// 累计（两类之和）。
  static int get totalFallbacks => emptyTimelineFallbacks + missingTimelineFallbacks;

  static void reset() {
    emptyTimelineFallbacks = 0;
    missingTimelineFallbacks = 0;
  }
}

/// 步进时用的增量记录器：比较各层 bundle 里 unitBars 数量变化，得出本步新确认的段。
class KnClockTimelineRecorder {
  final KnClockTimeline timeline = KnClockTimeline();
  final Map<int, int> _seenUnits = <int, int>{};

  void reset() {
    _seenUnits.clear();
  }

  /// [levels] 是当刻整条 bundle；每层各记一条轨（level = displayKn - 1）。
  void record(int asOf, List<LevelBundle> levels) =>
      recordKnClockStepInto(
        timeline: timeline,
        levels: levels,
        seenUnits: _seenUnits,
        asOf: asOf,
      );
}

/// 把一步的各层快照记进 [timeline]，并推进 [seenUnits] 增量游标（就地修改）。
///
/// 主图合并链（[StepFreezeSessionState.knClockSeenUnits]）与独立 harness
/// （[KnClockTimelineRecorder]）共用这一步，保证两条链产出的时间线一致。
void recordKnClockStepInto({
  required KnClockTimeline timeline,
  required List<LevelBundle> levels,
  required Map<int, int> seenUnits,
  required int asOf,
}) {
  final byLevel = <int, KnClockLevelStep>{};
  for (final lv in levels) {
    final seen = seenUnits[lv.level] ?? 0;
    // 游标可能被步退/重算打乱（新的 unitBars 比上次短），此时从当前长度重新起算。
    final start = seen > lv.unitBars.length ? lv.unitBars.length : seen;
    byLevel[lv.level] = KnClockLevelStep(
      newlyConfirmed: start < lv.unitBars.length
          ? lv.unitBars.sublist(start)
          : const <LevelUnitBar>[],
      activeUnit: lv.activeUnit,
    );
    seenUnits[lv.level] = lv.unitBars.length;
  }
  timeline.record(asOf, byLevel);
}