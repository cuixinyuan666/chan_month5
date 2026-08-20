#!/usr/bin/env bash
# CHAN_RUST 分支 Cloud Agent 一键装环境脚本
# 目标：把「计算层 Rust(chan_ffi/chan_data) + 展示层 Flutter(chan_kline)」环境一次装好。
# 幂等：可重复跑；已装好的机器再跑一遍也安全。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
echo "[install] 工程根目录: $REPO_ROOT"

CHAN_RUST_DIR="$REPO_ROOT/CHAN_RUST"
FLUTTER_APP_DIR="$CHAN_RUST_DIR/flutter/chan_kline"
FLUTTER_SDK_DIR="/opt/flutter"

# ---------------------------------------------------------------------------
# 1) 系统依赖：Rust 编译链 + Flutter Linux 桌面工具链(GTK/clang/cmake/ninja)
#    apt-get install 幂等；已装则很快跳过。libstdc++-14-dev 是 clang18 选中 gcc14
#    工具链时链接 -lstdc++ 必需（否则 CMake 编译器自检失败）。
# ---------------------------------------------------------------------------
echo "[install] 安装系统依赖 (编译链 + GTK 桌面工具链)"
sudo apt-get update -qq
sudo apt-get install -y -qq \
  build-essential pkg-config curl git unzip xz-utils zip \
  clang cmake ninja-build \
  libgtk-3-dev liblzma-dev libstdc++-14-dev \
  libgl1 libglu1-mesa

# ---------------------------------------------------------------------------
# 2) Rust 工具链：部分传递依赖需 edition2024（cargo>=1.85）；默认镜像可能停在 1.83。
# ---------------------------------------------------------------------------
if command -v rustup >/dev/null 2>&1; then
  echo "[install] 确保 Rust stable(cargo>=1.85)"
  rustup toolchain install stable --profile minimal >/dev/null 2>&1 || true
  rustup default stable >/dev/null 2>&1 || true
  echo "[install] cargo 版本: $(cargo --version 2>/dev/null || echo 未知)"
else
  echo "[install][警告] 未发现 rustup；若 chan_ffi 编译失败请检查 cargo>=1.85"
fi

# ---------------------------------------------------------------------------
# 3) Flutter SDK：装到 /opt/flutter（stable 频道），并软链到 /usr/local/bin 方便全局调用。
#    已存在则只更新，不重复 clone。
# ---------------------------------------------------------------------------
if [ ! -x "$FLUTTER_SDK_DIR/bin/flutter" ]; then
  echo "[install] 克隆 Flutter SDK (stable) 到 $FLUTTER_SDK_DIR"
  sudo git clone https://github.com/flutter/flutter.git -b stable --depth 1 "$FLUTTER_SDK_DIR"
  sudo chown -R "$(id -u):$(id -g)" "$FLUTTER_SDK_DIR"
else
  echo "[install] Flutter SDK 已存在，跳过 clone"
fi
git config --global --add safe.directory "$FLUTTER_SDK_DIR" || true
sudo ln -sf "$FLUTTER_SDK_DIR/bin/flutter" /usr/local/bin/flutter
sudo ln -sf "$FLUTTER_SDK_DIR/bin/dart" /usr/local/bin/dart
export PATH="$FLUTTER_SDK_DIR/bin:$PATH"

echo "[install] 开启 Linux 桌面 + 预拉取构建产物"
flutter config --enable-linux-desktop >/dev/null 2>&1 || true
flutter precache --linux >/dev/null 2>&1 || true
echo "[install] $(flutter --version 2>/dev/null | head -1)"

# ---------------------------------------------------------------------------
# 4) 编译 Rust 动态库 chan_ffi → libchan_ffi.so（Flutter 纯 FFI，Dart 无回退）
# ---------------------------------------------------------------------------
echo "[install] 编译 chan_ffi (release) 并复制 libchan_ffi.so"
bash "$CHAN_RUST_DIR/scripts/build_rust.sh"

# ---------------------------------------------------------------------------
# 5) Flutter 依赖 + 构建 Linux 桌面 bundle，并把 .so 复制进 bundle/lib（供直接运行）
# ---------------------------------------------------------------------------
echo "[install] flutter pub get"
( cd "$FLUTTER_APP_DIR" && flutter pub get )

echo "[install] 构建 Linux 桌面 debug bundle"
( cd "$FLUTTER_APP_DIR" && flutter build linux --debug )
# bundle 生成后再跑一次 build_rust.sh，把 libchan_ffi.so 落进 bundle/lib（RUNPATH=$ORIGIN/lib）
bash "$CHAN_RUST_DIR/scripts/build_rust.sh"

echo "[install] 完成 ✅"
echo "[install] 运行桌面应用: cd $FLUTTER_APP_DIR && flutter run -d linux"
echo "[install] Rust 单测: (cd $CHAN_RUST_DIR/rust && cargo test -p chan_data)"
