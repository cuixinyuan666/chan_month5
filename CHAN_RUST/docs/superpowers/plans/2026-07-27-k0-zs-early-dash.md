# K0���� + ������ƫ + ������� Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** ��ƫ����/������չʾ��Ϊ Kn������ K0���ࣨ�ϲ���ʵ�壩��չʾ����������/�������и�������

**Architecture:** ����/�ϲ���ǩ���䣻����/�������ǩ��Ϊ `K${kn}`��K0 ������ Rust �� `KlineCombineFrame` ӳΪα�κ��� `find_zs`/`ZSIncEngine`��Kn ����ͼ���Ƹ�Ϊչʾ�죺�����+active �� ���� `computeZSFrames(allowPrototype:true)`������ `isSure=false`��

**Tech Stack:** Rust `chan_data`/`chan_ffi`��Flutter `chan_kline`

## Global Constraints

- ȫ��ͬ��������д����δ��
- ��ȫ�ֿ� `one_bi_zs`�����ν�չʾ�����
- ���ָ� Auto/�������
- ����/�ϲ��� `K(n-1)`������/������� `Kn`
- Spec: `docs/superpowers/specs/2026-07-27-k0-zs-early-dash-design.md`

---

### Task 1: ����/������չʾ�� Kn ��ƫ

**Files:**
- Modify: `flutter/chan_kline/lib/models/chart_indicator.dart`
- Modify: `flutter/chan_kline/lib/widgets/kline_chart.dart`�����ڱ�ǩ��
- Modify: `flutter/chan_kline/lib/widgets/chart_level_line_style.dart`��ע�ͣ�
- Modify: ��� history / README �̾�

- [ ] **Step 1:** `zsNormal/zsOverSeg/bspNormal/bspOverSeg` �� `label` ��Ϊ `'K$kn����/������...'`������ `kn-1`��
- [ ] **Step 2:** `_drawZSOnMainChart` ��ǩ `'K$kn����...'`��BSP ��ǩͬ��
- [ ] **Step 3:** Ĭ��ѡ���� `zsNormal(1)` �� ����ʾ��K1���ࡹ

**Verify:** ָ���б� level1 ��ʾ K1���� ���� K0����

---

### Task 2: չʾ�쵥�γ��Σ�Dart compute + ��ͼ���ƣ�

**Files:**
- Modify: `lib/compute/zs_compute.dart` �� ���� `allowPrototype`
- Modify: `lib/widgets/kline_chart.dart` �� ʼ���ö���+active �������������
- Test: `test/zs_compute_test.dart`

**����:**
- `allowPrototype=true`��`segs.length>=1` ���ɣ����� 3 ʱ�õ���/���λ����� `isSure=false` ��
- �� 3 �������� Normal/OverSeg��ĩ������ `isSure=false`
- ���ƣ�`asOf` ��� asOf ����չʾ�죻append `activeUnit`���� endConfirm ����������

- [ ] **Step 1:** ���⣺1 �� �� 1 ��� isSure=false��3 �α�׼�����Կ�
- [ ] **Step 2:** ʵ�� `allowPrototype`
- [ ] **Step 3:** `_drawZSOnMainChart` ��װ segs+active ����֮

**Verify:** `flutter test test/zs_compute_test.dart`

---

### Task 3: Rust K0 �ϲ��� �� α�� �� ZS/BSP

**Files:**
- Modify: `rust/chan_data/src/zs.rs` �� `combine_frames_to_segs` / `level_zs_from_combine_frames`
- Modify: `rust/chan_data/src/combine.rs` �� Bundle ���� `zs_k0_*` / `bsp_k0_*`
- Modify: `rust/chan_data/src/bsp.rs` ���� `find_bsp`
- Test: zs.rs / combine.rs

**dir ����:** �� i ��Կ� i-1��`high+low` �е��� �� +1���� �� -1���׿� dir=+1

- [ ] **Step 1:** ���� 3 �������ϲ��� �� �ǿ� K0 ZS
- [ ] **Step 2:** ʵ��ӳ�� + �� Bundle
- [ ] **Step 3:** `build_rust.ps1`

---

### Task 4: Flutter ���� K0 ����/������

**Files:**
- Modify: models��Bundle �����򶥲��ֶΣ�
- Modify: `chart_indicator.dart` catalog ���� kn=0 �� zs/bsp
- Modify: `kline_chart.dart` ���� kn==0 �� combineFrames
- Modify: `main.dart` Ĭ�Ͽ�ѡ�� K0���ࣻhistory

- [ ] **Step 1:** ���� `zs_k0_normal_frames` ��
- [ ] **Step 2:** catalog + ���� + as-of��x2<=asOf �ϲ���
- [ ] **Step 3:** history ��פ˵��

**Verify:** �� K0�ϲ����ɹ�ѡ K0���ࣻ�������

---

### Task 5: �ĵ�������

- [ ] README / TASK_LOG / msg_history
- [ ] `cargo test -p chan_data --lib zs::`
- [ ] `flutter test` ���
- [ ] �ر� DLL

## Spec coverage

| Spec | Task |
|------|------|
| ���� Kn | 1 |
| K0=�ϲ�ʵ�� | 3�C4 |
| ������� | 2��+K0 ͬ�� 4�� |
| ������ͬ�� | 1 + 3�C4 |
| ���������� | 1��ֻ�� zs/bsp�� |
