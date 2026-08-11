#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""XGBoost 训练入口（stdin JSON → stdout JSON）。

约定（与 CHAN_RUST Flutter 导出 / Rust ml_predict 对齐）：
- libsvm 特征下标为 0-based（与 feature.meta / denseFromMeta 一致）
- 缺失值哨兵 = -9999999（MlFeatureFlat.missing / Rust MISSING）
- 自解析 libsvm 为 CSR，避免 XGB 默认 1-based 读法导致列偏移
- 校验 schema_version + meta 特征名有序表，不与 coreKeys 比
"""

from __future__ import annotations

import json
import os
import sys
import time
from typing import Any

MISSING = -9999999.0


def _fail(msg: str) -> None:
    print(json.dumps({"ok": False, "error": msg}, ensure_ascii=False))
    sys.exit(1)


def _load_meta(meta_path: str) -> dict[str, int]:
    with open(meta_path, "r", encoding="utf-8") as f:
        raw = json.load(f)
    if not isinstance(raw, dict) or not raw:
        raise ValueError(f"meta 为空或非对象: {meta_path}")
    out: dict[str, int] = {}
    for k, v in raw.items():
        out[str(k)] = int(v)
    return out


def _feature_names_ordered(meta: dict[str, int]) -> list[str]:
    n = max(meta.values()) + 1 if meta else 0
    names = [""] * n
    for name, idx in meta.items():
        if idx < 0 or idx >= n:
            raise ValueError(f"meta 下标越界: {name}={idx}")
        if names[idx]:
            raise ValueError(f"meta 下标冲突: {idx}")
        names[idx] = name
    if any(not x for x in names):
        raise ValueError("meta 下标不连续，存在空洞")
    return names


def _load_libsvm_0based(path: str, n_features: int):
    """按 0-based 解析 libsvm → (y, CSR)。缺省列即 missing。"""
    import numpy as np
    from scipy import sparse

    ys: list[float] = []
    rows: list[int] = []
    cols: list[int] = []
    data: list[float] = []
    with open(path, "r", encoding="utf-8") as f:
        for i, line in enumerate(f):
            line = line.strip()
            if not line:
                continue
            parts = line.split()
            ys.append(float(parts[0]))
            for p in parts[1:]:
                k_s, v_s = p.split(":", 1)
                k = int(k_s)
                if k < 0 or k >= n_features:
                    raise ValueError(f"{path}:{i+1} 特征下标 {k} 超出 meta 维 {n_features}")
                rows.append(len(ys) - 1)
                cols.append(k)
                data.append(float(v_s))
    if not ys:
        raise ValueError(f"空 libsvm: {path}")
    y = np.asarray(ys, dtype=np.float32)
    x = sparse.csr_matrix(
        (np.asarray(data, dtype=np.float32), (rows, cols)),
        shape=(len(ys), n_features),
    )
    return y, x


def _auc(y_true, y_score) -> float:
    import numpy as np

    y = np.asarray(y_true, dtype=np.float64)
    s = np.asarray(y_score, dtype=np.float64)
    pos = y == 1
    neg = y == 0
    n_pos = int(pos.sum())
    n_neg = int(neg.sum())
    if n_pos == 0 or n_neg == 0:
        return float("nan")
    order = np.argsort(s)
    ranks = np.empty_like(order, dtype=np.float64)
    ranks[order] = np.arange(1, len(s) + 1, dtype=np.float64)
    # 同分平均秩
    # 简化：若完全无并列，上面即可；有并列时用平均
    uniq, inv, counts = np.unique(s, return_inverse=True, return_counts=True)
    if (counts > 1).any():
        sum_ranks = np.bincount(inv, weights=ranks)
        avg = sum_ranks / counts
        ranks = avg[inv]
    sum_pos = float(ranks[pos].sum())
    return (sum_pos - n_pos * (n_pos + 1) / 2.0) / (n_pos * n_neg)


def _read_schema_version(run_meta_path: str | None) -> int | None:
    if not run_meta_path or not os.path.isfile(run_meta_path):
        return None
    with open(run_meta_path, "r", encoding="utf-8") as f:
        raw = json.load(f)
    v = raw.get("schema_version")
    return int(v) if v is not None else None


def main() -> None:
    try:
        import numpy as np
        import xgboost as xgb
    except ImportError as e:
        _fail(f"缺少依赖: {e}")

    raw_in = sys.stdin.read()
    if not raw_in.strip():
        _fail("stdin 为空，需要 JSON 配置")
    try:
        cfg = json.loads(raw_in)
    except json.JSONDecodeError as e:
        _fail(f"stdin JSON 解析失败: {e}")

    libsvm_path = cfg.get("libsvm_path") or cfg.get("train_path")
    valid_path = cfg.get("valid_path")
    meta_path = cfg.get("meta_path")
    output_dir = cfg.get("output_dir")
    model_path = cfg.get("model_path")
    sidecar_path = cfg.get("sidecar_path")
    run_meta_path = cfg.get("run_meta_path")
    expected_schema = cfg.get("schema_version")
    code = str(cfg.get("code") or "unknown")
    period = str(cfg.get("period") or "unknown")
    params = cfg.get("params") or {}
    force = bool(cfg.get("force_retrain", True))

    if not libsvm_path or not meta_path or not output_dir:
        _fail("缺少 libsvm_path/meta_path/output_dir")
    for p in (libsvm_path, meta_path):
        if not os.path.isfile(p):
            _fail(f"文件不存在: {p}")

    os.makedirs(output_dir, exist_ok=True)

    try:
        meta = _load_meta(meta_path)
        feature_names = _feature_names_ordered(meta)
    except Exception as e:
        _fail(f"meta 校验失败: {e}")

    n_features = len(feature_names)
    schema_ver = _read_schema_version(run_meta_path)
    if expected_schema is not None and schema_ver is not None:
        if int(expected_schema) != int(schema_ver):
            _fail(
                f"schema_version 不一致: 期望 {expected_schema}，导出 {schema_ver}"
            )
    if expected_schema is not None:
        schema_ver = int(expected_schema)

    if not model_path:
        sv = schema_ver if schema_ver is not None else 0
        model_path = os.path.join(
            output_dir, f"model_xgb_{code}_{period}_sv{sv}.json"
        )
    if not sidecar_path:
        sidecar_path = model_path.replace(".json", ".meta.json")
        if sidecar_path == model_path:
            sidecar_path = model_path + ".meta.json"

    # 指纹一致且未强制重训 → 跳过拟合，仍返回 ok（Flutter 可继续打分）
    if (not force) and os.path.isfile(model_path) and os.path.isfile(sidecar_path):
        try:
            with open(sidecar_path, "r", encoding="utf-8") as f:
                side = json.load(f)
            if (
                side.get("feature_names") == feature_names
                and side.get("index_base") == 0
                and side.get("missing_value") == MISSING
                and (
                    schema_ver is None
                    or side.get("schema_version") == schema_ver
                )
            ):
                print(
                    json.dumps(
                        {
                            "ok": True,
                            "skipped": True,
                            "model_path": model_path,
                            "sidecar_path": sidecar_path,
                            "train_auc": side.get("train_auc"),
                            "valid_auc": side.get("valid_auc"),
                            "num_rounds": side.get("num_rounds"),
                            "elapsed_sec": 0.0,
                            "feature_count": n_features,
                            "error": None,
                        },
                        ensure_ascii=False,
                    )
                )
                return
        except Exception:
            pass

    try:
        y_tr, x_tr = _load_libsvm_0based(libsvm_path, n_features)
    except Exception as e:
        _fail(f"读训练集失败: {e}")

    y_va = None
    x_va = None
    if valid_path and os.path.isfile(valid_path) and os.path.getsize(valid_path) > 0:
        try:
            y_va, x_va = _load_libsvm_0based(valid_path, n_features)
        except Exception as e:
            _fail(f"读验证集失败: {e}")

    max_depth = int(params.get("max_depth", 6))
    num_round = int(params.get("num_round", 100))
    learning_rate = float(params.get("learning_rate", 0.1))
    subsample = float(params.get("subsample", 0.8))
    colsample_bytree = float(params.get("colsample_bytree", 0.8))
    reg_alpha = float(params.get("reg_alpha", 0.0))
    reg_lambda = float(params.get("reg_lambda", 1.0))
    min_child_weight = float(params.get("min_child_weight", 3))
    gamma = float(params.get("gamma", 0.0))
    early_stopping = int(params.get("early_stopping_rounds", 20))

    # missing 哨兵与 Flutter/Rust 一致；稀疏缺列即 missing
    dtrain = xgb.DMatrix(x_tr, label=y_tr, missing=MISSING)
    evals: list[tuple[Any, str]] = [(dtrain, "train")]
    dvalid = None
    if x_va is not None:
        dvalid = xgb.DMatrix(x_va, label=y_va, missing=MISSING)
        evals.append((dvalid, "valid"))

    xgb_params = {
        "max_depth": max_depth,
        "eta": learning_rate,
        "subsample": subsample,
        "colsample_bytree": colsample_bytree,
        "alpha": reg_alpha,
        "lambda": reg_lambda,
        "min_child_weight": min_child_weight,
        "gamma": gamma,
        "objective": "binary:logistic",
        "eval_metric": "auc",
        "tree_method": "hist",
    }

    t0 = time.time()
    try:
        booster = xgb.train(
            xgb_params,
            dtrain,
            num_boost_round=num_round,
            evals=evals,
            early_stopping_rounds=early_stopping if dvalid is not None else None,
            verbose_eval=False,
        )
    except Exception as e:
        _fail(f"xgboost.train 失败: {e}")

    elapsed = time.time() - t0
    best_iter = getattr(booster, "best_iteration", None)
    if best_iter is not None and best_iter >= 0:
        used_rounds = int(best_iter) + 1
    else:
        used_rounds = int(num_round)

    pred_tr = booster.predict(dtrain, iteration_range=(0, used_rounds))
    train_auc = _auc(y_tr, pred_tr)
    valid_auc = float("nan")
    if dvalid is not None and y_va is not None:
        pred_va = booster.predict(dvalid, iteration_range=(0, used_rounds))
        valid_auc = _auc(y_va, pred_va)

    try:
        booster.save_model(model_path)
    except Exception as e:
        _fail(f"save_model 失败: {e}")

    sidecar = {
        "format": "chan_xgb_sidecar_v1",
        "schema_version": schema_ver,
        "code": code,
        "period": period,
        "index_base": 0,
        "missing_value": MISSING,
        "feature_names": feature_names,
        "feature_count": n_features,
        "model_path": model_path,
        "train_path": os.path.abspath(libsvm_path),
        "valid_path": os.path.abspath(valid_path) if valid_path else None,
        "params": {
            "max_depth": max_depth,
            "num_round": num_round,
            "learning_rate": learning_rate,
            "subsample": subsample,
            "colsample_bytree": colsample_bytree,
            "reg_alpha": reg_alpha,
            "reg_lambda": reg_lambda,
            "min_child_weight": min_child_weight,
            "gamma": gamma,
            "early_stopping_rounds": early_stopping,
        },
        "num_rounds": used_rounds,
        "train_auc": None if np.isnan(train_auc) else float(train_auc),
        "valid_auc": None if np.isnan(valid_auc) else float(valid_auc),
        "elapsed_sec": float(elapsed),
        "compat_note": (
            "Rust ml_predict 为简化树 walker；须读 default_left；"
            "dense 缺省填 MISSING=-9999999"
        ),
    }
    with open(sidecar_path, "w", encoding="utf-8") as f:
        json.dump(sidecar, f, ensure_ascii=False, indent=2)

    def _finite(v: float) -> float | None:
        return None if (v is None or (isinstance(v, float) and np.isnan(v))) else float(v)

    print(
        json.dumps(
            {
                "ok": True,
                "skipped": False,
                "model_path": model_path,
                "sidecar_path": sidecar_path,
                "train_auc": _finite(train_auc),
                "valid_auc": _finite(valid_auc),
                "num_rounds": used_rounds,
                "elapsed_sec": float(elapsed),
                "feature_count": n_features,
                "error": None,
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
