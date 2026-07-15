---
name: "skill-auto-update"
description: "代码改动后自动扫描并更新受影响的既有 skills。当修改了任何被既有 skill 引用的代码、配置、模式定义后，必须调用此 Skill 以保持 skills 与代码同步。"
---

# Skill 自动更新

## 触发条件

当以下任一情况发生时，**必须**调用此 Skill：

1. **修改了任何既有 skill 的 SKILL.md 中引用的文件**（如 `a_replay_trainer.py`、核心模块等）
2. **新增/删除/重命名配置项**，且该配置项在某个 skill 的"模式全景"或"检查清单"中被引用
3. **新增/删除/重命名模式维度**（chart_mode、data_form_mode、data_feed_mode、kline_presentation_mode 等）
4. **修改了某个模式的触发逻辑**，导致 skill 中描述的"触发条件"不再准确
5. **修改了核心计算模块的 API 或行为**，导致 skill 中的检查项过时

## 执行流程

### 第1步：收集本次改动信息

通过 `git diff` 或用户描述，收集以下信息：

- **改动了哪些文件**（相对路径）
- **改动类型**：新增/修改/删除
- **改动摘要**：简要描述每条改动的内容

### 第2步：扫描所有既有 skills

读取 `.trae/skills/` 下所有子目录中的 `SKILL.md`，提取每个 skill 的：

| 提取项 | 用途 |
|--------|------|
| `name` | skill 标识 |
| `description` | skill 用途 |
| "触发条件"章节 | 判断当前改动是否命中 |
| "模式全景"章节 | 配置项/模式引用列表 |
| "检查清单"章节 | 逐项检查条目 |
| 所有文件引用 | 形如 `文件名.py`、`目录/`、`配置项名` 的文本 |

### 第3步：命中判定

对每个既有 skill，检查本次改动是否命中其"触发条件"或引用的文件/配置：

```
命中条件（满足任一即命中）：
  A. 改动的文件出现在 skill 的"触发条件"中
  B. 改动的文件出现在 skill 正文的任何位置
  C. 新增/删除/重命名的配置项出现在 skill 的"模式全景"或"检查清单"中
  D. 新增/删除的模式维度需要补充到 skill 的"模式全景"中
  E. 改动改变了某个模式的行为，skill 中的描述不再准确
```

### 第4步：生成更新计划

对每个命中的 skill，列出需要更新的具体条目：

```
skill: <name>
  - [ ] 更新"触发条件"：<原因>
  - [ ] 更新"模式全景"：<原因>
  - [ ] 更新"检查清单"第N条：<原因>
  - [ ] 更新文件引用：<原因>
  - [ ] 无需更新（仅提示用户确认）
```

### 第5步：执行更新（需用户确认）

将更新计划呈现给用户，用户确认后逐个执行 `Edit` 操作更新对应 `SKILL.md`。

**更新原则：**
- **只改受影响的条目**，不重写整个 skill
- **保持原有格式和风格**（表格、缩进、编号等）
- **新增内容使用中文**，与现有 skill 语言一致
- **不确定的地方标注 `<!-- TODO: 需人工确认 -->`**，等待用户补充

### 第6步：验证

更新完成后，重新读取所有被修改的 `SKILL.md`，检查：

- frontmatter 格式正确（`---` 包裹，`name` 和 `description` 字段完整）
- 无明显的格式断裂（表格对齐、列表编号连续等）
- 新增内容与现有内容无矛盾

---

## 当前工程既有 Skills 清单

| Skill 名称 | 文件 | 依赖的关键文件/配置 |
|------------|------|---------------------|
| `chan-mode-compat` | `.trae/skills/chan-mode-compat/SKILL.md` | `a_replay_trainer.py`、Bi/、Seg/、ZS/、KLine/、BuySellPoint/、配置项（chart_mode、data_form_mode、data_feed_mode、kline_presentation_mode、data_form_quantity、data_form_quantity_alloc 等） |
| `chan-framework-ref` | `.trae/skills/chan-framework-ref/SKILL.md` | `DataAPI/`、`Common/CEnum.py`、`ChanConfig.py`、`Chan.py`、`a_replay_trainer.py`（数据源注册）、数据源常量和优先级链 |
| `chan-cross-ref-impact` | `.trae/skills/chan-cross-ref-impact/SKILL.md` | 所有核心模块（Bi/、Seg/、ZS/、KLine/、BuySellPoint/、Math/、Common/） |
| `chan-rust-rewrite` | `.trae/skills/chan-rust-rewrite/SKILL.md` | `chan-core/`（Rust 项目）、核心计算模块（Bi/Seg/ZS/KLine/Combiner/BuySellPoint/Math）、PyO3 绑定、JNI 绑定 |
| `chan-chip-distribution` | `.trae/skills/chan-chip-distribution/SKILL.md` | `a_replay_trainer.py`（筹码数据源选择、kline_all 管理、chip_tick_bins 注入/下发）、`a_replay_core/a_perf_engine.py`（chip_profile 分桶）、`a_rust_core/src/lib.rs`（Rust 侧 chip_profile）、`a_replay_core/a_replay_kline_view.py`（volume_chip 视图）、前端筹码渲染/筹码峰指标 |
| `chan-step-rhythm` | `.trae/skills/chan-step-rhythm/SKILL.md` | `a_replay_trainer.py`（节奏线副图计算、bundle 构建、前端渲染）、`chart_lazy_layers`（step_rhythm 懒加载）、`rhythm_calc_mode` 三种计算模式 |
| `chan-adjacent-bi-ratio` | `.trae/skills/chan-adjacent-bi-ratio/SKILL.md` | `a_replay_trainer.py`（相邻笔比例副图计算、前端渲染）、`chart_lazy_layers`（adjacent_bi_ratio 懒加载）、旧版 `retrace_ratio/trend_ratio` 兼容映射 |
| `chan-zhongshu` | `.trae/skills/chan-zhongshu/SKILL.md` | `ZS/ZS.py`（CZS 数据结构）、`ZS/ZSList.py`（CZSList 计算主流程 cal_bi_zs）、`ZS/ZSConfig.py`（CZSConfig 配置）、`KLine/KLine_List.py`（cal_seg_and_zs / update_zs_in_seg）、`a_replay_trainer.py`（build_level_zs / serialize_zs_collection / chart_lazy_zs_enabled / zs_levels）、`a_rust_core/chan-core/src/zs.rs`（Rust 侧 Zs/ZsList）、前端 drawZsRects 渲染、payload 字段 fract_zs/bi_zs/seg_zs/segseg_zs/extra_zs |
| `skill-auto-update` | `.trae/skills/skill-auto-update/SKILL.md` | 所有 `SKILL.md` 文件（自身） |

---

## 注意事项

1. **持久化兼容**：`a_replay_trainer.py` 使用了持久化机制，新增/删除配置项时需同步检查 skill 中的配置清单是否需要更新。
2. **模块化原则**：如果新功能引入了新的模块目录，skill 中的文件引用列表应及时补充。
3. **防遗漏**：即使某个 skill 看起来"可能不受影响"，也应列入更新计划让用户确认。
4. **本次改动应同时更新本 skill 的"既有 Skills 清单"**：如果新增或删除了 skill，本文件中的清单表也应同步维护。