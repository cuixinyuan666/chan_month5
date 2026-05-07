from typing import Any, Optional


def serialize_klu_iter_fast(klu_iter, serialize_klu_unit_fast_fn, volume_getter_fn) -> list[dict[str, Any]]:
    arr: list[dict[str, Any]] = []
    for klu in klu_iter:
        arr.append(serialize_klu_unit_fast_fn(klu, volume_getter_fn))
    return arr


def serialize_chan_with_cache(
    chan,
    indicator_history: list,
    trend_lines: list,
    *,
    build_structure_bundle_fn,
    serialize_klu_iter_fn,
    serialize_line_collection_fn,
    serialize_zs_collection_fn,
    serialize_kline_combine_fn,
    serialize_bsp_collection_fn,
    level_order: dict[str, int],
    chan_algo: str,
    bundle=None,
    kline_all: Optional[list[dict[str, Any]]] = None,
    klu_arr_cache: Optional[list[dict[str, Any]]] = None,
) -> dict[str, Any]:
    """序列化 chart 输出；None 的 kline_all 表示不下发该字段。"""
    kl_list = chan[0]
    klu_arr = klu_arr_cache if klu_arr_cache is not None else serialize_klu_iter_fn(kl_list.klu_iter())
    active_bundle = bundle or build_structure_bundle_fn(chan, chan_algo)
    fract_arr = serialize_line_collection_fn(active_bundle.fract_list)
    bi_arr = serialize_line_collection_fn(active_bundle.bi_list)
    seg_arr = serialize_line_collection_fn(active_bundle.seg_list)
    segseg_arr = serialize_line_collection_fn(active_bundle.segseg_list)
    fract_zs_arr = serialize_zs_collection_fn(active_bundle.fractzs_list)
    bi_zs_arr = serialize_zs_collection_fn(active_bundle.zs_list)
    seg_zs_arr = serialize_zs_collection_fn(active_bundle.segzs_list)
    segseg_zs_arr = serialize_zs_collection_fn(active_bundle.segsegzs_list)
    kline_combine_arr = serialize_kline_combine_fn(kl_list)
    bsp_bi_arr = serialize_bsp_collection_fn("bi", active_bundle.bs_point_lst)
    bsp_seg_arr = serialize_bsp_collection_fn("seg", active_bundle.seg_bs_point_lst)
    bsp_segseg_arr = serialize_bsp_collection_fn("segseg", active_bundle.segseg_bs_point_lst)
    bsp_arr = sorted(
        [*bsp_bi_arr, *bsp_seg_arr, *bsp_segseg_arr],
        key=lambda item: (int(item["x"]), level_order.get(str(item["level"]), 999), int(not bool(item["is_buy"]))),
    )
    out: dict[str, Any] = {
        "kline": klu_arr,
        "fract": fract_arr,
        "bi": bi_arr,
        "seg": seg_arr,
        "segseg": segseg_arr,
        "fract_zs": fract_zs_arr,
        "bi_zs": bi_zs_arr,
        "seg_zs": seg_zs_arr,
        "segseg_zs": segseg_zs_arr,
        "bsp": bsp_arr,
        "bsp_bi": bsp_bi_arr,
        "bsp_seg": bsp_seg_arr,
        "bsp_segseg": bsp_segseg_arr,
        "rhythm_lines": active_bundle.rhythm_lines,
        "rhythm_hits": active_bundle.rhythm_hits,
        "fx_lines": active_bundle.fx_lines,
        "indicators": indicator_history,
        "trend_lines": active_bundle.trend_lines if active_bundle.trend_lines else trend_lines,
        "kline_combine": kline_combine_arr,
    }
    if kline_all is not None:
        out["kline_all"] = kline_all
    return out

