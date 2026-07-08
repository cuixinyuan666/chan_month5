# CHAN_RUST

全新缠论子项目：**计算层 Rust**，**展示层 Flutter**。与上层 Python `chan.py` 解耦，首期从 `a_Data` 离线分笔聚合 K 线并绘制蜡烛图。

## 目录结构

```
CHAN_RUST/
├── README.md
├── scripts/
│   └── build_rust.ps1      # 编译 Rust 并复制 DLL 到 Flutter Windows
├── rust/
│   ├── chan_data/          # a_Data 分笔解析 + K 线聚合（纯 Rust）
│   └── chan_ffi/           # Flutter FFI（JSON 桥）
└── flutter/
    └── chan_kline/         # Flutter K 线应用
```

## 数据路径

默认读取 `chan.py/a_Data/`（与 `CHAN_RUST` 同级的离线分笔目录），与 Python `COfflineInline` 分笔格式一致。

## 环境要求

- Rust 1.70+
- Flutter 3.x（已测 Windows 桌面）
- 数据源：`../a_Data` 下已有分笔 txt

## 构建与运行（Windows）

```powershell
# 1. 编译 Rust 并复制 chan_ffi.dll
.\CHAN_RUST\scripts\build_rust.ps1

# 2. 启动 Flutter 桌面
cd CHAN_RUST\flutter\chan_kline
flutter pub get
flutter run -d windows
```

## Rust 本地测试

```powershell
cd CHAN_RUST\rust
cargo test -p chan_data
```

## FFI 接口（chan_ffi）

| 函数 | 说明 |
|------|------|
| `chan_default_data_root()` | 返回默认 a_Data 路径 JSON |
| `chan_list_stock_codes(data_root)` | 枚举六位代码目录 |
| `chan_load_klines(root, code, begin, end, period)` | 加载 K 线 JSON 数组 |
| `chan_free_string(ptr)` | 释放返回字符串 |

`period` 支持：`1m` `5m` `15m` `60m` `day` `week` `month` 等。

## 后续规划

- [ ] 缠论笔/段/中枢 Rust 核心
- [ ] Android JNI 复用 `chan_data`
- [ ] 逐 K 步进与当下性 BSP
