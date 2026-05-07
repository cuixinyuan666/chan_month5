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

###背景
1.我编写的文件或文件夹以a_开头，并且可更改的文件只有一个：replay_trainer.py，replay_trainer.py的部分使用说明位于：a_replay_trainer_操作说明.md。a_replay_trainer_操作说明.md也包含了quick_guide.md的内容。如果我明确的提出需要增加除了replay_trainer.py的文件，我需要你根据我的需求，增加对应的文件，所有文件或者文件夹使用a_开头的命名规范；
2.a_Data是我自定义的离线数据文件；
3.当前工程的说明基于quick_guide.md(不包含replay_trainer.py的说明，除非你需要整体了解全工程，不然不需要查看该文档)，是作业本，README.md是个答案本（通常不需要查看），是我将要或者以后要实现的版本。
4.README.md包含quick_guide.md，当前工程有很多功能并不在README.md中。
5.当前终端可使用playwright、git、winget、curl；
6.当前的工程包含了大量中国交易体系：缠中说禅的逻辑。

###代码规范
1.写成的代码加上注释；
2.注释尽量简短，注释尽量使用我和你沟通时使用的专业或者非专业的术语，且尽量使用中文；
3.文件的更改只限于replay_trainer.py，其余当前工程的文件禁止增，删；
4.UI端设计时尽量使用中文；
5.尽量最大性价比的使用TOKEN，不进行非必要操作。
