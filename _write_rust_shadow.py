# -*- coding: utf-8 -*-
from pathlib import Path
p = Path("a_replay_core/a_rust_chan_shadow.py")
p.write_text(p.read_text(encoding="utf-8", errors="replace"), encoding="utf-8")
