/// 特征序列线框（Rust `EigenFrame`）。

class EigenFrame {

  final int slot;

  final int x1;

  final int x2;

  final double high;

  final double low;

  final String fx;

  final int biCount;



  const EigenFrame({

    required this.slot,

    required this.x1,

    required this.x2,

    required this.high,

    required this.low,

    required this.fx,

    required this.biCount,

  });



  factory EigenFrame.fromJson(Map<String, dynamic> json) {

    return EigenFrame(

      slot: (json['slot'] as num?)?.toInt() ?? 0,

      x1: (json['x1'] as num).toInt(),

      x2: (json['x2'] as num).toInt(),

      high: (json['high'] as num).toDouble(),

      low: (json['low'] as num).toDouble(),

      fx: json['fx'] as String? ?? 'UNKNOWN',

      biCount: (json['bi_count'] as num?)?.toInt() ?? 1,

    );

  }

}



/// 段确认柱（Rust `SegConfirmSignal`）。

class SegConfirmSignal {

  final int x;

  final String fx;

  final int value;

  final int endedSegDir;

  final int peakBiIdx;

  final int fractalX1;

  final int fractalX2;

  final double fractalHigh;

  final double fractalLow;



  const SegConfirmSignal({

    required this.x,

    required this.fx,

    required this.value,

    required this.endedSegDir,

    required this.peakBiIdx,

    this.fractalX1 = 0,

    this.fractalX2 = 0,

    this.fractalHigh = 0,

    this.fractalLow = 0,

  });



  factory SegConfirmSignal.fromJson(Map<String, dynamic> json) {

    return SegConfirmSignal(

      x: (json['x'] as num).toInt(),

      fx: json['fx'] as String? ?? '',

      value: (json['value'] as num).toInt(),

      endedSegDir: (json['ended_seg_dir'] as num).toInt(),

      peakBiIdx: (json['peak_bi_idx'] as num?)?.toInt() ?? -1,

      fractalX1: (json['fractal_x1'] as num?)?.toInt() ?? 0,

      fractalX2: (json['fractal_x2'] as num?)?.toInt() ?? 0,

      fractalHigh: (json['fractal_high'] as num?)?.toDouble() ?? 0,

      fractalLow: (json['fractal_low'] as num?)?.toDouble() ?? 0,

    );

  }

}



/// 首段方向锁定（Rust `FirstSegDirSignal`）。

class FirstSegDirSignal {

  final int x;

  final int dir;



  const FirstSegDirSignal({required this.x, required this.dir});



  factory FirstSegDirSignal.fromJson(Map<String, dynamic> json) {

    return FirstSegDirSignal(

      x: (json['x'] as num).toInt(),

      dir: (json['dir'] as num).toInt(),

    );

  }

}



/// 已确认线段（主图展示，不参与 ML）。

class SegLine {

  final int idx;

  final int dir;

  final int beginX;

  final int endX;

  final int beginFractalX1;

  final int beginFractalX2;

  final int endFractalX1;

  final int endFractalX2;

  final double beginPrice;

  final double endPrice;



  const SegLine({

    required this.idx,

    required this.dir,

    required this.beginX,

    required this.endX,

    required this.beginPrice,

    required this.endPrice,

    this.beginFractalX1 = 0,

    this.beginFractalX2 = 0,

    this.endFractalX1 = 0,

    this.endFractalX2 = 0,

  });



  factory SegLine.fromJson(Map<String, dynamic> json) {

    return SegLine(

      idx: (json['idx'] as num).toInt(),

      dir: (json['dir'] as num).toInt(),

      beginX: (json['begin_x'] as num).toInt(),

      endX: (json['end_x'] as num).toInt(),

      beginFractalX1: (json['begin_fractal_x1'] as num?)?.toInt() ?? 0,

      beginFractalX2: (json['begin_fractal_x2'] as num?)?.toInt() ?? 0,

      endFractalX1: (json['end_fractal_x1'] as num?)?.toInt() ?? 0,

      endFractalX2: (json['end_fractal_x2'] as num?)?.toInt() ?? 0,

      beginPrice: (json['begin_price'] as num).toDouble(),

      endPrice: (json['end_price'] as num).toDouble(),

    );

  }

}



/// 逐 K 副图快照（Rust `BarSubSnapshot`）。

class BarSubSnapshot {

  final int idx;

  final int buildingSegDir;

  final int firstSegDir;

  final int segConfirm;

  final int eigenSlot;

  final List<EigenFrame> eigenFrames;



  const BarSubSnapshot({

    required this.idx,

    required this.buildingSegDir,

    required this.firstSegDir,

    required this.segConfirm,

    this.eigenSlot = -1,

    this.eigenFrames = const [],

  });



  factory BarSubSnapshot.fromJson(Map<String, dynamic> json) {

    return BarSubSnapshot(

      idx: (json['idx'] as num?)?.toInt() ?? 0,

      buildingSegDir: (json['building_seg_dir'] as num?)?.toInt() ?? 0,

      firstSegDir: (json['first_seg_dir'] as num?)?.toInt() ?? 0,

      segConfirm: (json['seg_confirm'] as num?)?.toInt() ?? 0,

      eigenSlot: (json['eigen_slot'] as num?)?.toInt() ?? -1,

      eigenFrames: (json['eigen_frames'] as List? ?? const [])

          .map((e) => EigenFrame.fromJson(Map<String, dynamic>.from(e as Map)))

          .toList(),

    );

  }



  String get eigenFx {

    for (final f in eigenFrames.reversed) {

      if (f.fx != 'UNKNOWN') return f.fx;

    }

    return eigenFrames.isNotEmpty ? eigenFrames.last.fx : 'UNKNOWN';

  }

}



/// 段分析整包（Rust `SegAnalysisBundle`）。

class SegAnalysisBundle {

  final List<EigenFrame> eigenFrames;

  final List<SegConfirmSignal> segConfirms;

  final List<FirstSegDirSignal> firstSegDirSignals;

  final List<SegLine> segLines;

  final List<BarSubSnapshot> barSubSnapshots;

  final int buildingSegDir;

  final int firstSegDir;



  const SegAnalysisBundle({

    this.eigenFrames = const [],

    this.segConfirms = const [],

    this.firstSegDirSignals = const [],

    this.segLines = const [],

    this.barSubSnapshots = const [],

    this.buildingSegDir = 0,

    this.firstSegDir = 0,

  });



  factory SegAnalysisBundle.fromJson(Map<String, dynamic> json) {

    return SegAnalysisBundle(

      eigenFrames: (json['eigen_frames'] as List? ?? const [])

          .map((e) => EigenFrame.fromJson(Map<String, dynamic>.from(e as Map)))

          .toList(),

      segConfirms: (json['seg_confirms'] as List? ?? const [])

          .map((e) => SegConfirmSignal.fromJson(Map<String, dynamic>.from(e as Map)))

          .toList(),

      firstSegDirSignals: (json['first_seg_dir_signals'] as List? ?? const [])

          .map((e) => FirstSegDirSignal.fromJson(Map<String, dynamic>.from(e as Map)))

          .toList(),

      segLines: (json['seg_lines'] as List? ?? const [])

          .map((e) => SegLine.fromJson(Map<String, dynamic>.from(e as Map)))

          .toList(),

      barSubSnapshots: (json['bar_sub_snapshots'] as List? ?? const [])

          .map((e) => BarSubSnapshot.fromJson(Map<String, dynamic>.from(e as Map)))

          .toList(),

      buildingSegDir: (json['building_seg_dir'] as num?)?.toInt() ?? 0,

      firstSegDir: (json['first_seg_dir'] as num?)?.toInt() ?? 0,

    );

  }



  BarSubSnapshot? snapshotAt(int idx) {

    for (final s in barSubSnapshots) {

      if (s.idx == idx) return s;

    }

    return null;

  }



  static SegAnalysisBundle empty() => const SegAnalysisBundle();

}


