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

套件登记见仓库根 [`ROBOT_VERIFY.md`](../../ROBOT_VERIFY.md)。

## 连续单步数据（002003）

验收区间固定为 `2004/07/19 10:47:00`～`2004/07/20 13:09:00`。App 会按顺序探测：

1. 环境变量 `CHAN_DATA_ROOT`（若设置）
2. 仓库 `a_Data`、上级 `../a_Data`、Rust 默认数据根
3. 在仓库内浅层检索含 `002003/*.txt` 的目录
4. 本地文件失败时，对候选根目录尝试通达信协议分笔（与主图非 test 股一致）

仓库内 `a_Data/002003` 可为空；本机另有备份时无需拷贝到固定路径。
