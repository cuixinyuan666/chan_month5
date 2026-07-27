# 设计：删除跨段中枢 + Normal/OverSeg 双中枢双买卖点

日期：2026-07-27

## 决策摘要

1. **删除**整条「跨段中枢」KuaDuanV1（计算 / JSON / 主图指标 / as-of / 测试）。
2. **原生中枢**拆为两套独立主图指标（呈现对齐原原生中枢框）：
   - `K(n-1)中枢(Normal)`
   - `K(n-1)中枢(OverSeg)`
3. **买卖点**同步拆两套：
   - `K(n-1)买卖点(Normal)`
   - `K(n-1)买卖点(OverSeg)`
4. **放弃 Auto**：不实现旧工程「确定用 normal / 不确定用 over_seg」；Rust 枚举去掉 `Auto`。
5. **流水线双算双输出**（方案 1）：每层始终各算 Normal / OverSeg 各一份 ZS + BSP。

## JSON 键

| 键 | 含义 |
|----|------|
| `zs_normal_frames` | Normal 算法中枢框 |
| `zs_over_seg_frames` | OverSeg 算法中枢框 |
| `bsp_normal_frames` | 基于 Normal 中枢的三类买卖点 |
| `bsp_over_seg_frames` | 基于 OverSeg 中枢的三类买卖点 |

废弃：`kuaduan_frames`、`zs_frames`、`bsp_frames`（不再产出）。

## 全层同构

两套算法均在 K0/K1/…/KN 每层对已冻结段独立计算；十字 as-of 本地重算与末态同口径；不回写、无未来。

## 历史记录

追加一条口径变更说明：KuaDuan 已删；主图由「原生中枢」改为 Normal/OverSeg；买卖点双套；Auto 放弃。保留 `lib/history/` 与复制/查看按钮。
