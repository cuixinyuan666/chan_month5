#!/usr/bin/env bash
# Cloud Agent 一键装环境脚本（缠论回测/研究工程）
# 幂等：可重复跑；每步都能在“已装好”的机器上安全再跑一遍。
set -euo pipefail

# 定位工程根目录（本脚本在 <repo>/.cursor/ 下）
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
echo "[install] 工程根目录: $REPO_ROOT"

# ---------------------------------------------------------------------------
# 1) 系统依赖：pyo3/maturin 编译要 Python.h（python3-dev），外加基础编译链
#    apt-get install 本身幂等；已装则跳过。
# ---------------------------------------------------------------------------
if ! [ -f /usr/include/python3.12/Python.h ] && ! python3 -c "import sysconfig,os,sys; sys.exit(0 if os.path.exists(os.path.join(sysconfig.get_path('include'),'Python.h')) else 1)"; then
  echo "[install] 安装系统编译依赖 (python3-dev / build-essential / pkg-config)"
  sudo apt-get update -qq
  sudo apt-get install -y -qq python3-dev python3-venv build-essential pkg-config
else
  echo "[install] 系统 Python 开发头文件已就绪，跳过 apt 安装"
fi

# ---------------------------------------------------------------------------
# 2) Rust 工具链：某些传递依赖需要 edition2024（要求 cargo >= 1.85）。
#    默认镜像可能停留在 1.83，这里把 stable 装上并设为默认。
# ---------------------------------------------------------------------------
if command -v rustup >/dev/null 2>&1; then
  echo "[install] 确保 Rust stable 工具链（edition2024 需 cargo>=1.85）"
  rustup toolchain install stable --profile minimal >/dev/null 2>&1 || true
  rustup default stable >/dev/null 2>&1 || true
  echo "[install] cargo 版本: $(cargo --version 2>/dev/null || echo '未知')"
else
  echo "[install][警告] 未发现 rustup，跳过工具链升级；若 Rust 扩展编译失败请检查 cargo>=1.85"
fi

# ---------------------------------------------------------------------------
# 3) Python 虚拟环境 + 依赖
# ---------------------------------------------------------------------------
if [ ! -d "$REPO_ROOT/.venv" ]; then
  echo "[install] 创建虚拟环境 .venv"
  python3 -m venv "$REPO_ROOT/.venv"
fi
# shellcheck disable=SC1091
source "$REPO_ROOT/.venv/bin/activate"

echo "[install] 升级 pip 并安装 Python 依赖"
python -m pip install --upgrade pip -q
pip install -q -r "$REPO_ROOT/.cursor/requirements.txt"

# ---------------------------------------------------------------------------
# 4) 编译并安装 Rust 极速引擎扩展 a_rust_core_ext（rust_auto 模式必需）
#    maturin develop 会把扩展装进当前 venv，import a_rust_core_ext 即可用。
# ---------------------------------------------------------------------------
if [ -f "$REPO_ROOT/a_rust_core/pyproject.toml" ]; then
  echo "[install] 用 maturin 编译 Rust 扩展 a_rust_core_ext (release)"
  ( cd "$REPO_ROOT/a_rust_core" && maturin develop --release )
  python -c "import a_rust_core_ext; print('[install] Rust 扩展导入成功: a_rust_core_ext')"
else
  echo "[install][警告] 未找到 a_rust_core/pyproject.toml，跳过 Rust 扩展编译"
fi

echo "[install] 完成 ✅  （激活环境: source .venv/bin/activate）"
