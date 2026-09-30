# 机器人验证落盘目录

运行时文件由 App / 脚本写入，**勿提交**（见仓库根 `.gitignore`）。

## 启用半自动验证

1. 口头授权后，复制模板为本地会话（仅本机）：

   ```powershell
   Copy-Item session.json.example session.json
   ```

2. 编辑 `session.json`：`active` 设为 `true`，填写 `taskTitle`、`authorizedAt`、`authorizedBy`。
3. 用户自行编译并启动 App；结束后将剪贴板 JSON 粘贴回对话。
4. 任务结束后将 `active` 改回 `false`，或删除 `session.json`。

套件登记见仓库根 [`agent.md`](../../agent.md)。
