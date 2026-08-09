# ML 规格：K0 一类 BS 闭环（schema_version=1）

对齐开源 [Vespa314/chan.py machinelearning](https://github.com/Vespa314/chan.py/tree/machinelearning) 的 `Debug/strategy_demo5.py` / `strategy_demo6.py`。

## 新手用法

1. 设置选好股票 / 周期 / 起止时间。
2. 点 **机器学习**（后台取数与计算，**不加载 / 不展示 K 线图**）。
3. App：完整逐 K 跳末 → 采集 K0 一类 BS 事件特征 → α 打标 → **按比例切分训练/考试集**。
4. 成果页默认看 **考试集**：α 准确率 + 样本 √/× 列表；可切换训练集/全部。
5. 拖动 **训练比例**（50%–90%）可立即重切，无需重算。
6. **导出数据**：`feature_train.libsvm` / `feature_exam.libsvm` + `feature.meta` + `*_exam_report.json`（`feature.libsvm`=训练集兼容旧名）。
7. 用**训练集**外部训练后，将 `model.json` 放到 `ml_exports/`，点 **加载模型预测**，在考试集上看模型准确率（阈值 0.5）。
8. **退出机器学习** 回复盘界面。

## 样本与 Label

| 项 | 口径 |
|----|------|
| 锚点 | 仅 K0 一类 BS（`1Ba/1Sa…`）发现当下 |
| 特征 | 该步 tip/lookup 同源固定键（扁平化）；禁止 tip 动态行名 |
| α | 跳末后仍在正确一类集合 → √，否则 × |
| 极值 | Ba 须为对应 **K0连线** 最低点；Sa 须为最高点（不符→×） |
| 切分 | 按样本 `x` 时间序；默认训练 70% / 考试 30%；样本≥2 时考试至少 1 条 |

## 模型

- 推荐：`chan_ml_v1` JSON：`{"format":"chan_ml_v1","bias":0,"weights":[...],"objective":"logistic"}`（weights 长度=meta 特征数，按下标对齐）。
- 亦尝试解析简化版 XGBoost `model.json` trees。
- 缺省值：`-9999999`（对齐 demo6 missing）。

## FFI

`chan_ml_predict({ model_path, dense }) -> { score }`

## UI 约束

- ML 主区**不挂 K 线图**；后台仍用 `_loadKlines` + `_runToEnd` 算特征（非 UI 加载）。
- 不改 tip/`BarFeatureLookup` 生产逻辑。
