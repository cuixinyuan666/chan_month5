# -*- mode: python ; coding: utf-8 -*-
# pyinstaller ml_train_xgb.spec
# 产出 dist/ml_train_xgb.exe → 复制到
# CHAN_RUST/flutter/chan_kline/windows/native/ml_train_xgb.exe

block_cipher = None

a = Analysis(
    ['ml_train_xgb.py'],
    pathex=[],
    binaries=[],
    datas=[],
    hiddenimports=[
        'xgboost',
        'numpy',
        'scipy',
        'scipy.sparse',
        'sklearn',
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name='ml_train_xgb',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
