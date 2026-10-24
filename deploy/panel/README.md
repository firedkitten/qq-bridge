# 本地面板（SSH 隧道 + Web 控制台）

一键把服务器的三个界面和服务状态搬到本地浏览器，不用记 IP、不用每次手敲端口转发。

## 怎么用

双击 `deploy\启动管理面板.cmd`

1. 启动时自动在桌面补建/刷新快捷方式 **QQ Bot 管理面板**（电脑图标），以后双击它就行；不小心删了，下次启动又会自己回来。
2. 它会在后台拉起 `ssh -N -L ...` 建隧道，再启动本地面板并自动打开浏览器：
   **http://127.0.0.1:7788**
3. **关闭那个黑色窗口 = 断开隧道**（面板和 ssh 一起退出；右下角 network icon 不会残留）。
4. 如果面板已经在跑，再双击只会打开浏览器，不会重复启动。

面板本身只监听 `127.0.0.1:7788`，公网访问不到。

## 面板里有什么

| 区块 | 内容 |
| --- | --- |
| 入口 | qq-bridge 控制台（自动带 token）、SnowLuma WebUI `:5099`、QQ 扫码桌面 `:6081`，并直接显示 noVNC 密码 |
| 服务器 | 主机名 / 系统 / 内核 / 虚拟化 / 运行时长 |
| 资源占用 | CPU 核心数、负载、内存条、磁盘条（>75% 变黄，>90% 变红） |
| 服务状态 | qq-bridge、dsh-web、snowluma-configperm.timer 的 active/其他 |
| 机器人 | 昵称、QQ 号、已加入的群（群名 + 人数） |
| 运行环境 | node / docker 版本、运行中的容器 |
| 运行日志 | bridge / snowluma 容器 / snowluma 应用日志 / dsh，四个 tab，5 秒自动刷新 |

## 端口映射

| 本地 | 服务器 | 用途 |
| --- | --- | --- |
| 3100 | 127.0.0.1:3100 | qq-bridge 控制台 |
| 5099 | 127.0.0.1:5099 | SnowLuma WebUI |
| 6081 | 127.0.0.1:6081 | noVNC（QQ 扫码桌面） |
| 3380 | 127.0.0.1:3080 | DSH Web（本地 3080 被你自己的 DSH 占用，所以挪到 3380） |

## 配置

改 `panel.config.json` 即可，不用动代码：

```json
{
  "host": "<服务器公网IP>",
  "user": "root",
  "key": "../../id_ed25519",
  "consoleToken": "…",
  "vncPassword": "<noVNC 密码>",
  "botQQ": "<机器人QQ>",
  "panelPort": 7788,
  "forwards": [[3100, 3100], [5099, 5099], [6081, 6081], [3380, 3080]]
}
```

- `key` 相对 `panel\` 目录，也可以用绝对路径。
- 换服务器只改 `host` / `user` / `key` / `consoleToken`。
- `forwards` 是 `[本地端口, 服务器端口]` 的数组；面板的入口按钮和端口标签会自动跟着它变，改完重启面板即可。
- 本地端口被占（比如 3100 已有别的程序）就改 `forwards` 左边的数，比如 `[13100, 3100]`。

## 出问题先看这些

| 现象 | 原因 / 处理 |
| --- | --- |
| 窗口一闪而过 | 装了 Node 却没在 PATH 里，或 `id_ed25519` 不在仓库根目录；脚本会停住并提示 |
| 桌面快捷方式没生成 | 现在由 `make-shortcut.vbs`（cscript）生成，失败才退到 `make-shortcut.ps1`。旧版失败是因为用户名带 `'`（如 `<你的用户名>`）会截断内联 PowerShell 的单引号字符串，已规避。彻底不行就手动：右键 `启动管理面板.cmd` → 发送到 → 桌面快捷方式 |
| `UNPROTECTED PRIVATE KEY FILE` | 私钥权限太宽。修：`icacls "<仓库路径>\id_ed25519" /inheritance:r /grant:r "%USERNAME%:(R)"`（需管理员或对该文件有改权限） |
| 面板显示"隧道已断开（自动重连）" | 服务器 SSH 断了 / 网络抖动；它会 2s→30s 退避重连。看窗口日志 |
| 服务状态全红 | 服务器上 systemd 服务停了：`ssh` 进去 `systemctl status qq-bridge dsh-web` |
| noVNC 密码不对 | 容器重建后会随机换密码：`docker logs snowluma 2>&1 | grep -i "remote desktop password"`，同步改 `panel.config.json` 的 `vncPassword` |
| 日志一片空白 | 该服务确实没输出；换另一个 tab 看 |

隧道日志和 ssh 的原始报错在 `deploy\panel\run\tunnel.log`（自动生成）。
