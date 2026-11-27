# a_Data/002003 —— 默认测试/调试数据（重要，别删）

## 这是什么

- `*.txt` 是 **002003（深市002003）按自然日切分的逐笔数据**，每个文件一天
  （如 `20250929_002003.txt`）。**这些是仓库的默认数据**，`test/` 下绝大多数
  采样钟、寻优、回测用例都直接读它们，是**事实上的回归基准**。
- 读取入口：`ChanBridge.instance.loadKlinesEx(dataRoot: bridge.defaultDataRoot(),
  code: '002003', period: '1m', tickSource: 'protocol', ...)`。
  见 `test/kn_clock_causality_test.dart`、`test/run_to_end_vs_step_freeze_test.dart` 等。
- 仓库里只跟踪 `a_Data/002003/.gitkeep`（占位，保证目录存在）；数据文件本身**不入库**。

## 为什么保留、不删

| 考量 | 结论 |
| --- | --- |
| 速度 | 12.5 MB / 247 个文件。删掉后**每一次**跑 `flutter test` 都要重新下载，且依赖网络；跑一次全量测试约 25 分钟，缺数据直接跑不起来。 |
| agent 能否找到入口 | 本文件就是入口。以前只有 `.gitkeep`，agent 看到一堆积压未跟踪文件，既不知道是什么，也不敢动。 |
| 仓库体积 | 不入库，`.gitignore` 已忽略，对 clone 体积零影响。 |

## 与 `.tdx_protocol_cache/` 的关系

`a_Data/.tdx_protocol_cache/002003/` 下是**同一批 247 个文件的重复副本**
（同文件名、同体积）。前者是读路径，后者是下载缓存，保留两份是为了避免
每次读都跨目录。两者都在 `.gitignore` 内。

## 风险与注意

- 这些文件被 `.gitignore` 忽略，因此 **`git clean -fdx` 会删掉它们**。
  清理工作区前请确认，或改用 `git clean -nd` 先看。
- 缺文件时重新生成：跑一次相关测试（会自动走 protocol 下载），
  或用 App 内数据管理重新拉取。