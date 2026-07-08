"""纯特征序列线段确认：标准三元素分型 + 有效突破；第三元素支持笔内K突破，不等整笔确认。"""
from __future__ import annotations

from typing import Any, Optional

from Common.CEnum import BI_DIR, SEG_TYPE

from .a_pure_eigen_fx import APureEigenFX, make_a_pure_eigen_fx


class APureEigenSegTracker:
    """逐K增量追踪纯特征序列分型，供段确认副图消费（当下性：笔内破 E 即可确认）。"""

    def __init__(self, level: str = "seg", lv: SEG_TYPE = SEG_TYPE.BI):
        self.level = str(level)
        self.lv = lv
        self._processed_upto = -1
        self._seg_begin_idx = 0
        self._building_dir: BI_DIR = BI_DIR.UP
        self._up_eigen: APureEigenFX = make_a_pure_eigen_fx(BI_DIR.UP, lv=lv)
        self._down_eigen: APureEigenFX = make_a_pure_eigen_fx(BI_DIR.DOWN, lv=lv)

    def reset(self) -> None:
        self._processed_upto = -1
        self._seg_begin_idx = 0
        self._building_dir = BI_DIR.UP
        self._up_eigen.clear()
        self._down_eigen.clear()

    def _line_dir(self, line: Any) -> BI_DIR:
        return line.dir

    def _line_is_up(self, line: Any) -> bool:
        return self._line_dir(line) == BI_DIR.UP

    def _line_is_down(self, line: Any) -> bool:
        return self._line_dir(line) == BI_DIR.DOWN

    def _active_eigen(self) -> Optional[tuple[APureEigenFX, BI_DIR, BI_DIR]]:
        """返回 (eigen, ended_seg_dir, required_forming_dir)。"""
        if self._building_dir == BI_DIR.UP:
            return self._up_eigen, BI_DIR.UP, BI_DIR.DOWN
        if self._building_dir == BI_DIR.DOWN:
            return self._down_eigen, BI_DIR.DOWN, BI_DIR.UP
        return None

    def _make_event(
        self,
        fx_eigen: APureEigenFX,
        lines: list[Any],
        ended_seg_dir: BI_DIR,
        *,
        intra: bool = False,
    ) -> dict[str, Any]:
        peak_bi_idx = int(fx_eigen.GetPeakBiIdx())
        peak_line = lines[peak_bi_idx]
        evidence_line = getattr(fx_eigen, "last_evidence_bi", None) or peak_line
        evidence_klu = getattr(fx_eigen, "last_evidence_klu", None)
        begin_idx = max(0, int(self._seg_begin_idx))
        begin_line = lines[begin_idx] if begin_idx < len(lines) else lines[0]
        fx_ele = fx_eigen.ele[1]
        fx_type = getattr(fx_ele, "fx", None)
        fx_name = getattr(fx_type, "name", str(fx_type))
        evidence_idx = int(getattr(evidence_line, "idx", -1))
        if evidence_klu is not None:
            evidence_x = int(evidence_klu.idx)
        else:
            evidence_x = int(evidence_line.get_end_klu().idx)
        return {
            "event_type": "pure_eigen_fx",
            "level": self.level,
            "reason": "pure_eigen_fx_intra_k" if intra else "pure_eigen_fx",
            "dir": ended_seg_dir,
            "fx_type": fx_name,
            "idx": peak_bi_idx,
            "peak_bi_idx": peak_bi_idx,
            "evidence_bi_idx": evidence_idx,
            "begin_x": int(begin_line.get_begin_klu().idx),
            "anchor_x": int(peak_line.get_end_klu().idx),
            "evidence_x": evidence_x,
            "y1": float(begin_line.get_begin_val()),
            "y2": float(peak_line.get_end_val()),
        }

    def _on_seg_confirmed(self, ended_seg_dir: BI_DIR, end_line: Any) -> None:
        self._up_eigen.clear()
        self._down_eigen.clear()
        try:
            self._seg_begin_idx = int(getattr(end_line, "idx", -1)) + 1
        except Exception:
            self._seg_begin_idx = 0
        self._building_dir = BI_DIR.DOWN if ended_seg_dir == BI_DIR.UP else BI_DIR.UP

    def _try_intra_k_confirm(self, lines: list[Any], latest_klu: Any) -> list[dict[str, Any]]:
        if latest_klu is None or not lines:
            return []
        tail = lines[-1]
        if bool(getattr(tail, "is_sure", False)):
            return []
        active = self._active_eigen()
        if active is None:
            return []
        eigen, ended_seg_dir, forming_dir = active
        if self._line_dir(tail) != forming_dir or not eigen.ready_for_intra_k_third():
            return []
        if not eigen.try_intra_k_third_confirm(tail, latest_klu):
            return []
        event = self._make_event(eigen, lines, ended_seg_dir, intra=True)
        self._on_seg_confirmed(ended_seg_dir, tail)
        return [event]

    def feed_new_lines(self, lines: list[Any], latest_klu: Any = None) -> list[dict[str, Any]]:
        """增量喂入子线；已确认笔走完整第三元素，未确认笔可走笔内K突破。"""
        if not lines:
            return []
        events: list[dict[str, Any]] = []
        start = max(0, self._processed_upto + 1)
        for i in range(start, len(lines)):
            line = lines[i]
            if not bool(getattr(line, "is_sure", False)):
                break
            self._processed_upto = i
            if self._building_dir == BI_DIR.UP and self._line_is_down(line):
                eigen = self._up_eigen
                confirmed = False
                if latest_klu is not None and eigen.ready_for_intra_k_third():
                    if eigen.try_intra_k_third_confirm(line, latest_klu):
                        events.append(self._make_event(eigen, lines, BI_DIR.UP, intra=True))
                        self._on_seg_confirmed(BI_DIR.UP, line)
                        confirmed = True
                if not confirmed and eigen.add(line):
                    events.append(self._make_event(eigen, lines, BI_DIR.UP))
                    self._on_seg_confirmed(BI_DIR.UP, line)
            elif self._building_dir == BI_DIR.DOWN and self._line_is_up(line):
                eigen = self._down_eigen
                confirmed = False
                if latest_klu is not None and eigen.ready_for_intra_k_third():
                    if eigen.try_intra_k_third_confirm(line, latest_klu):
                        events.append(self._make_event(eigen, lines, BI_DIR.DOWN, intra=True))
                        self._on_seg_confirmed(BI_DIR.DOWN, line)
                        confirmed = True
                if not confirmed and eigen.add(line):
                    events.append(self._make_event(eigen, lines, BI_DIR.DOWN))
                    self._on_seg_confirmed(BI_DIR.DOWN, line)
        events.extend(self._try_intra_k_confirm(lines, latest_klu))
        return events


def make_pure_eigen_seg_trackers(levels: tuple[str, ...] = ("seg", "segseg")) -> dict[str, APureEigenSegTracker]:
    out: dict[str, APureEigenSegTracker] = {}
    for level in levels:
        lv = SEG_TYPE.BI if level == "seg" else SEG_TYPE.SEG
        out[level] = APureEigenSegTracker(level=level, lv=lv)
    return out
