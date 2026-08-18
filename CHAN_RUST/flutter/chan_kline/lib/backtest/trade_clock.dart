/// 回测三件套：Clock + 可交易变量契约 + 成交永远在 K0。
///
/// 必须冻结的 7 条（阶段0就把钟定死，后面公式才不会错钟）：
/// 1. 回测不建立第二套指标计算真相。
/// 2. 交易变量必须通过可交易变量契约层暴露。
/// 3. 变量身份至少含 displayKn + clockFamily + evalClock + plotClock。
/// 4. 条件计算只能发生在变量自己的 evalClock 上（禁止拿铺平后的 K0 阶梯做 CROSS）。
/// 5. 所有实际成交统一落到 K0 时间轴（没有「下一根 K3 开盘」）。
/// 6. 回测逐 K 必须复用现有逐 K pipeline / 增量结果。
/// 7. 策略信号与缠论一类/二类 BS 完全分离。

/// 方案B 两套取样钟：同一条规则只改层号时，必须仍在同一套钟里。
enum TradeClockFamily {
  /// 中枢 / 布林 / MACD 同号：K0=原生K；K1+ = 结构层 level==kn-1 的虚拟K
  zsMath,
  /// 连线族同号：数据在结构层 level==kn（比例/斜率/节奏）
  line,
}

/// 序列真正跳动的那根钟（条件只在这根钟上算）。
enum TradeEvalClock {
  /// 原生 K0 一根一根
  k0Bar,
  /// 该层虚拟 K 样本（冻段+动态段）；每条样本的 availableAt=右端 K0
  knSample,
}

/// 给人看时铺到哪一根轴（Kn 数学指标会铺成 K0 格子，那是看的，不是算 CROSS 的）。
enum TradePlotClock {
  k0Bar,
}

/// 成交钟：永远是 K0。本阶段只定契约，不做撮合。
enum TradeExecutionClock {
  /// 当根 K0 出信号，下一根 K0 开盘成交
  k0NextOpen,
}

const TradeExecutionClock kTradeExecutionClock = TradeExecutionClock.k0NextOpen;

/// 策略回测成交价：发现根当根收盘，或下一根开盘（均在 K0 轴）。
enum TradeFillPriceMode {
  /// 发现当根 K0 收盘价（默认；信号当步已知后按收盘撮合）
  sameBarClose,
  /// 下一根 K0 开盘价（保守；无下一根则订单过期）
  nextBarOpen,
}

/// 回测设置默认：本周期收盘价。
const TradeFillPriceMode kDefaultTradeFillPriceMode =
    TradeFillPriceMode.sameBarClose;

String tradeFillPriceModeLabel(TradeFillPriceMode mode) => switch (mode) {
      TradeFillPriceMode.sameBarClose => '本周期收盘价',
      TradeFillPriceMode.nextBarOpen => '次周期开盘价',
    };

/// displayKn=0 → 原生K0；≥1 → 该层虚拟K样本。
TradeEvalClock evalClockForDisplayKn(int displayKn) =>
    displayKn <= 0 ? TradeEvalClock.k0Bar : TradeEvalClock.knSample;
