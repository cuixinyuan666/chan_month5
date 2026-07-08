"""自定义纯特征序列：标准三元素分型 + 有效突破（不含 can_be_end 等线段附加过滤）。"""
from __future__ import annotations

from typing import Any, Optional

from Bi.Bi import CBi
from Common.CEnum import BI_DIR, FX_TYPE, KLINE_DIR, SEG_TYPE
from Seg.Eigen import CEigen
from Seg.EigenFX import CEigenFX


class APureEigenFX(CEigenFX):
    """段确认副图专用：分型判定对齐原生 actual_break，但不走 can_be_end / find_revert_fx。"""

    def __init__(self, _dir: BI_DIR, exclude_included=True, lv=SEG_TYPE.BI):
        super().__init__(_dir, exclude_included=exclude_included, lv=lv)
        self.last_evidence_klu: Any = None

    def clear(self):
        super().clear()
        self.last_evidence_klu = None

    def ready_for_intra_k_third(self) -> bool:
        """前两特征元素已齐、第三元素尚未落位，可尝试笔内K突破确认。"""
        return self.ele[0] is not None and self.ele[1] is not None and self.ele[2] is None

    def a_actual_break(self) -> bool:
        """有效突破：原生 actual_break + 破第一特征元素极值（用户标准 G 破 E 低）。"""
        if not self.exclude_included:
            return True
        if self.actual_break():
            return True
        assert self.ele[0] is not None and self.ele[1] is not None and self.ele[2] is not None
        if self.is_up() and self.ele[2].low < self.ele[0].low:
            return True
        if self.is_down() and self.ele[2].high > self.ele[0].high:
            return True
        return False

    def _finalize_third_fractal(self, bi: CBi, allow_top_equal: Optional[int]) -> bool:
        if not self.a_actual_break():
            self.ele[2] = None
            return False
        self.ele[1].update_fx(
            self.ele[0],
            self.ele[2],
            exclude_included=self.exclude_included,
            allow_top_equal=allow_top_equal,
        )  # type: ignore[arg-type]
        fx = self.ele[1].fx
        is_fx = (self.is_up() and fx == FX_TYPE.TOP) or (self.is_down() and fx == FX_TYPE.BOTTOM)
        if not is_fx:
            self.ele[2] = None
            return False
        return True

    def _first_break_klu_in_bi(self, bi: CBi) -> Any:
        """第三元素笔内首次破 E 低/高的 K（与笔内确认阈值一致）。"""
        ele1 = self.ele[1]
        if ele1 is None:
            return bi.get_end_klu()
        try:
            for klc in bi.klc_lst:
                for klu in klc.lst:
                    if self.is_up() and float(klu.low) < float(ele1.low):
                        return klu
                    if self.is_down() and float(klu.high) > float(ele1.high):
                        return klu
        except Exception:
            pass
        return bi.get_end_klu()

    def treat_third_ele(self, bi: CBi) -> bool:
        assert self.ele[0] is not None
        assert self.ele[1] is not None
        self.last_evidence_bi = bi
        self.last_evidence_klu = None
        allow_top_equal = (1 if bi.is_down() else -1) if self.exclude_included else None
        combine_dir = self.ele[1].try_add(bi, allow_top_equal=allow_top_equal)
        if combine_dir == KLINE_DIR.COMBINE:
            return False
        self.ele[2] = CEigen(bi, combine_dir)
        if not self._finalize_third_fractal(bi, allow_top_equal):
            return self.reset()
        if self.last_evidence_klu is None:
            self.last_evidence_klu = self._first_break_klu_in_bi(bi)
        return True

    def try_intra_k_third_confirm(self, forming_line: Any, evidence_klu: Any) -> bool:
        """第三元素未确认笔：当前K破 E 低/高即确认分型，不等整笔走完。"""
        if evidence_klu is None or not self.ready_for_intra_k_third():
            return False
        if getattr(forming_line, "dir", None) == self.dir:
            return False
        try:
            klu_low = float(evidence_klu.low)
            klu_high = float(evidence_klu.high)
        except Exception:
            return False

        ele1 = self.ele[1]
        assert ele1 is not None
        if self.is_up():
            e_low = float(ele1.low)
            if klu_low >= e_low:
                return False
        else:
            e_high = float(ele1.high)
            if klu_high <= e_high:
                return False

        self.last_evidence_bi = forming_line
        self.last_evidence_klu = evidence_klu
        allow_top_equal = (1 if forming_line.is_down() else -1) if self.exclude_included else None
        combine_dir = ele1.try_add(forming_line, allow_top_equal=allow_top_equal)
        if combine_dir == KLINE_DIR.COMBINE:
            self.last_evidence_klu = None
            return False
        self.ele[2] = CEigen(forming_line, combine_dir)
        if not self._finalize_third_fractal(forming_line, allow_top_equal):
            self.last_evidence_klu = None
            return self.reset()
        return True


def make_a_pure_eigen_fx(_dir: BI_DIR, lv: SEG_TYPE = SEG_TYPE.BI) -> APureEigenFX:
    return APureEigenFX(_dir, exclude_included=True, lv=lv)
