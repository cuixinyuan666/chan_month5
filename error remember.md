---
tags:
  - chan/记忆
  - chan-month5
created: 2026-10-02
date: 2026-10-02
moc: "[[chan-month5/index-memory]]"
---

# error remember（智能体常见错误与解法）

> [!info] 定位
> 记录智能体在本工程**反复犯的错**、**踩过的坑**及其**解法**，并收录用户转述词汇。
> 规则正文见 AGENTS.md；本文件是「出错 → 怎么改」的落地清单。

## 一、用户转述词汇（只记两类）

只收：**① 映射到本工程具体文件 / 脚本，检索时用得上；② 不看表就一定会误解的**。
像 `wancheng`（完成）、`tianjia`（添加）这类靠上下文就能猜准的**一律不记** —— 表一大就没人维护，必然失效。

| 用户写法 | 标准中文 | 本工程落点 |
| --- | --- | --- |
| `bianyi` / `compile` | 编译 | 跑 `CHAN_RUST/scripts/build_rust.ps1`；会杀旧 App 并自动启动新 App |
| `chongqi` | 重启 | 同上：走 `build_rust.ps1`，不手动单独重启 |
| `yanzheng` | 验证 | 机器人验证模式（`session.json active=true`）或冷启动连续单步验收 |
| `queren` / `ok` | 确认 | 等同「确认执行」门禁里的「确认」，有授权效力 |
| `ceshi` / `run test` | 测试 | 实跑一次验证，不是「写测试代码」 |

## 二、常犯的错与解法

### 1. 把 bianyi 当成「变异」
- **现象**：用户说需要 bianyi，我理解成「变异」，先提了 App 内快捷键方案，绕了三个来回才对上「编译」。
- **根因**：拼音多音同形，靠猜。
- **解法**：拼音有歧义就停下来问、并复述「我听到的是 X，指的是 Y 吗」；本工程 bianyi 一律指**编译**。

### 2. 把编译输出重定向到 build_windows_last.log
- **现象**：脚本第 70 行报 out-file 文件正被另一进程使用，flutter build 没跑起来就退出。
- **根因**：该文件是脚本自己的 buildLog（第 13 行）要写的，重定向抢占了句柄。
- **解法**：智能体输出重定向到 **build_rust_run.log**；build_windows_last.log 是 flutter 构建日志（UTF-16），**只看不改**。

### 3. 前台跑 build_rust.ps1
- **现象**：工具调用一直不返回。
- **根因**：脚本末尾以前台方式执行 exe，会阻塞到用户手动关掉 App。
- **解法**：一律用 Start-Process 后台跑，再轮询 build_rust_run.log 判成败。

### 4. PowerShell 吞掉反引号
- **现象**：python -c 里的反引号被当转义符，字符串悄悄变形，assert 莫名失败或写出残缺内容。
- **解法**：Python 里用 chr(96) 代替反引号；中文内容走 PowerShell 单引号数组或 JSON 文件中转，**别塞进双引号命令行**。

### 5. here-string 终止符粘连
- **现象**：写成 @Set-Content 被解析成一句，报「表达式或语句中包含意外的标记」。
- **解法**：here-string 的收尾 @ 必须**独占一行**，后面换行再写下一条命令；不稳定时改用数组逐行写文件。

### 6. App 正在运行时编译
- **现象**：DLL / exe 被占用，复制或覆盖失败。
- **根因**：Windows 不允许覆盖正在运行的 exe。
- **解法**：让脚本先杀旧 App（它第 22-25 行已内置 Stop-Process），不要在 App 运行时手工编。

## 三、怎么用

- 自己犯过错就顺手追加一条「现象 / 根因 / 解法」。
- 只记**复发代价高**的错；一次性的手滑不记。
- 与 AGENTS.md 冲突时，以 AGENTS.md 为准。
