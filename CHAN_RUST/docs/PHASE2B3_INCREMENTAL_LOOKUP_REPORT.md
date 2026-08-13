# Phase 2B-3A Incremental Lookup 报告

范围：仅 Flutter presentation/cache。未改 Rust / Delta / 算法 / History / asOf 语义。
`BarFeatureLookup.build` 保留为黄金参考。

## 正确性

`flutter test test/incremental_lookup_session_test.dart` 全过：

- 002003 step24–28：Incremental == Full（当前行 + 冻结 idx=5 + ML flatten；含一类/二类/N类 BS、ZS、分型判断键）
- reset+replay 后 Incremental == Full
- asOf=24..28：当前行 == Full(asOf)；冻结 weekday 一致；asOf+1 不泄漏

`pipeline_delta_session_test` 仍全过。

## Profiling（末步，002003 1m）

| N | Delta(ffi+decode+fromJson+merge) | FullLookup | IncrementalLookup | 加速 | step 总耗时 |
|---|---|---|---|---|---|
| 200 | 21ms | 237ms | 170ms | 1.4x | 192ms |
| 500 | 64ms | 424ms | 263ms | 1.6x | 327ms |
| 1000 | 106ms | 1162ms | 325ms | 3.6x | 431ms |
| 2000 | 307ms | 6259ms | 1048ms | 6.0x | 1355ms |

- Full 随 N 增长 **26.4x**（N=200→2000）——仍是全表三型。
- Incremental 增长 **6.2x** ——量/Math 按柱填格的 O(N)，不是每根 x × 层 × 确认数。
- Painter 复用 `lookupEngine`：N=200 render pump **2219ms**（不再 2× Full build）。

## 边界

本阶段停止。不进入 Phase 2C。
剩余 O(N) 填格（量/Math 为对齐 Full 的层回填）是否再砍，等下一步批准。
