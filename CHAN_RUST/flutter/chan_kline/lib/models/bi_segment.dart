/// 笔段：相邻异向分型配对，含 prev/next 连续关联（Rust `BiSegment`）。

class BiSegment {

  final int idx;

  final int dir;

  final int beginConfirmX;

  final int endConfirmX;

  final int beginFractalX1;

  final int beginFractalX2;

  final int endFractalX1;

  final int endFractalX2;

  final int? prevIdx;

  final int? nextIdx;



  const BiSegment({

    required this.idx,

    required this.dir,

    required this.beginConfirmX,

    required this.endConfirmX,

    required this.beginFractalX1,

    required this.beginFractalX2,

    required this.endFractalX1,

    required this.endFractalX2,

    this.prevIdx,

    this.nextIdx,

  });



  factory BiSegment.fromJson(Map<String, dynamic> json) {

    return BiSegment(

      idx: (json['idx'] as num).toInt(),

      dir: (json['dir'] as num).toInt(),

      beginConfirmX: (json['begin_confirm_x'] as num).toInt(),

      endConfirmX: (json['end_confirm_x'] as num).toInt(),

      beginFractalX1: (json['begin_fractal_x1'] as num).toInt(),

      beginFractalX2: (json['begin_fractal_x2'] as num).toInt(),

      endFractalX1: (json['end_fractal_x1'] as num).toInt(),

      endFractalX2: (json['end_fractal_x2'] as num).toInt(),

      prevIdx: (json['prev_idx'] as num?)?.toInt(),

      nextIdx: (json['next_idx'] as num?)?.toInt(),

    );

  }

}


