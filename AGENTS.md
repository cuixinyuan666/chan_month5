---
description: 
alwaysApply: true
---

---
description: 
alwaysApply: true
---

---
description: 
alwaysApply: true
---

# AGENTS.md

## Environment

- **Python 3.11+ required** (project is compute-intensive; 3.11 improves speed ~16% over 3.8)
- Not a pip package; run modules directly (e.g., `python main.py`)
- Dependencies: `pip install -r a_Script/a_requirements.txt`
  - `replay_trainer.py` needs extra: `fastapi uvicorn akshare tushare pydantic`

## Running

```bash
python main.py              # demo: compute Chan elements, render plot
python replay_trainer.py   # FastAPI replay/training server
```

## Architecture

Entrypoints:
- `Chan.py` → `CChan` class: main computation engine
- `ChanConfig.py` → `CChanConfig`: all computation parameters
- `main.py`: demo script (BaoStock, daily K-line, plot to `test.png`)

Key directories (each is a module, not a package):
- `Bi/` → strokes (笔), `Seg/` → segments (线段), `ZS/` → central zones (中枢)
- `KLine/` → K-line merging & unit classes
- `BuySellPoint/` → BSP (形态学买卖点)
- `DataAPI/` → data sources (BaoStock default, AKShare, Tushare, Futu, ccxt, CSV, custom)
- `Math/` → indicators (MACD, BOLL, RSI, KDJ, Demark)
- `Plot/` → matplotlib rendering (`CPlotDriver`, `CAnimateDriver`)
- `Common/` → enums (`CEnum.py`), utilities, `CTime`, cache decorator

## Data Sources

Configure via `CChan(data_src=...)`:
- `DATA_SRC.BAO_STOCK` (default), `DATA_SRC.AKSHARE`, `DATA_SRC.TUSHARE`, `DATA_SRC.FUTU`, `DATA_SRC.CCXT`, `DATA_SRC.CSV`
- Custom: `"custom:module.ClassName"`

BaoStock & Futu require `do_init()`/`do_close()` (login/logout).

## Key Configuration Facts

- `CChanConfig({})` accepts a dict; see `README.md` § "CChanConfig 配置" for all keys
- `trigger_step=True`: incremental mode (generator, call `chan.step_load()` per K-line)
- `bi_strict=True` (default): strict stroke algorithm
- `zs_algo`: `normal` (within-segment), `over_seg` (cross-segment), `auto`
- `kl_data_check=True` (default): validates K-line ordering and cross-level alignment
- `only_judge_last=True`: fast mode, computes only latest K-line signals

## Element Certainty

All elements have `is_sure` flag:
- `is_sure=True` → finalized, never changes on new K-lines
- `is_sure=False` → appears as dashed lines in plots, may change/disappear
- Unsure elements only exist at head/tail of the sequence

## Incremental / Replay

- `trigger_step=True` + `CChan.step_load()`: feed K-lines one-by-one
- `replay_trainer.py` → `ReplayChan`: deep-copies cached K-lines, re-computes with new config
- External K-line feed: `CChan.trigger_load(Dict[KL_TYPE, List[CKLine_Unit]])`

## Serialization

- Deep recursion in linked elements (`.next`/`.pre` pointers); increase limit:
  ```python
  import sys; sys.setrecursionlimit(0x100000)
  ```
- Use `chan.chan_dump_pickle("chan.pkl")` / `CChan.chan_load_pickle("chan.pkl")`

## Plotting

- `CPlotDriver`: static plot → `plot_driver.figure.show()` or `.save2img(path)`
- `CAnimateDriver`: animation (experimental, known memory leak on long sequences)
- `plot_config` dict: toggle elements (e.g., `plot_bi`, `plot_seg`, `plot_zs`, `plot_bsp`)
- `plot_para` dict: fine-tune per-element rendering

## Docs

- `quick_guide.md` → open-source version guide (follow this, not README, for this codebase)
- `README.md` → full-version docs (some files/features not in open-source edition)

## No Tests / Linting

No test framework, no linting config, no CI found. Verify changes manually with `python main.py`.

###角色
你是一个资深的python 量化程序员，具有完整的Python和股票理论基础。

###分支信息
当前分支：`full-optimization`（全面优化），基于`trae_cn`创建。
此分支是一个过渡版本，约半年后将移植到Android平台。因此：
- 代码设计需兼顾"后续移植Android的便利性"与"当前Python环境的极致性能"。
- 尽量使用纯Python/Cython/NumPy实现，避免过度依赖桌面端特有库。
- 核心计算逻辑与UI渲染逻辑应清晰分离，便于后续Android端替换UI层。

###当前工程介绍
1.a_replay_trainer.py的使用说明位于：a_quick_guide.md。a_quick_guide.md也包含了quick_guide.md的全部内容,此文件在我没有明确指示前禁止修改；
2.a_Data是我自定义的离线数据文件,a_replay_trainer.py的引用包为我的自定义包：a_replay_cache，a_replay_core，a_Script；
3.README.md是个答案本（通常不需要查看），是我将要或者以后要实现的版本。
4.README.md包含quick_guide.md，当前工程有很多功能并不在README.md中。
5.当前终端可使用playwright、git、winget、curl；
6.当前的工程包含了大量中国交易体系：缠中说禅的逻辑。

###代码设计规范
1.写成的代码加上注释；
2.注释尽量简短，注释尽量使用我和你沟通时使用的专业或者非专业的术语，且尽量使用中文；
3.当前分支下，允许修改工程内所有文件（不限于"a_"开头的文件），包括核心计算模块（Bi/、Seg/、ZS/、KLine/、BuySellPoint/、Math/、Common/、DataAPI/、Plot/等），以追求极致性能为目标；
4.UI端设计时尽量使用中文；
5.增加任何设置时注意和当前前后端中的所有模式所有周期的适配性，如果你十分不确定可以提出疑问，如果有通常做法则提醒用户即可；
6.a_replay_trainer.py使用了可持久化，需要你增删改代码或者增删改设置时，时刻注意；
   - 新增或调整任何可持久化设置时，必须同步加入默认选择项/默认值注册，避免新用户或清空缓存后出现空配置。
7.增加设置时尽可能添加弹窗显示该设置的操作逻辑和操作步骤；
8.代码的设计应模块化，在后续添加其它功能时可以方便复用；
9.如果生成了测试代码或者文件，在调试结束后应当删除无用代码；
10.尽量最大性价比的使用TOKEN，不进行非必要操作；
11.优化后的核心计算模块应尽量与UI/渲染解耦，便于半年后移植到Android。

## frontend-design skill 使用场景

- 当需要重设前端界面、优化表单布局、调整 K 线图配置面板、交易按钮区、弹窗或回测面板视觉层级时，优先参考 `.codex/skills/frontend-design/SKILL.md`。
- 使用该 skill 时，先明确界面用途、目标用户、性能/持久化约束，再做低干扰、高密度、适合交易终端的 UI 设计。
