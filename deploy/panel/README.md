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
| 入口 | qq-bridge 控制台（自动带 token）、SnowLuma WebUI `:5099`、QQ 扫码桌面 `:6081`、服务器 DSH（点击时现取登录 token 再跳转，免去翻 journalctl），并直接显示 noVNC 密码 |
| 服务器 | 主机名 / 系统 / 内核 / 虚拟化 / 运行时长 |
| 资源占用 | CPU 核心数、负载、内存条、磁盘条（>75% 变黄，>90% 变红） |
| 服务状态 | qq-bridge、dsh-web、snowluma-configperm.timer 的 active/其他 |
| 机器人 | 昵称、QQ 号、已加入的群。每行群的排版是「第一行=群名称（过长省略，悬停看全名）/ 第二行=群号 / 右侧=当前成员数 ÷ 群人数上限 + 占用条」。成员数是**实时**取的：`get_group_list` 必须带 `no_cache:true`，否则 SnowLuma 返回的是进程启动时的缓存（群改名、新人进群都不会变）。断线时整块变灰而不是清空，顶部有「xs 前」数据年龄与「立即刷新」 |
| 运行环境 | node / docker 版本、运行中的容器 |
| 运行日志 | bridge / snowluma 容器 / snowluma 应用日志 / dsh，四个 tab，5 秒自动刷新 |

## 右下角工具坞（深色 / 浅色）

页面右下角常驻一个圆形按钮组，目前只有「深色 / 浅色」一个按钮：

- 点一下在深色与**白色简约**浅色之间切换，选择存在 `localStorage`（`panel-theme`），刷新后保持。
- 浅色主题只覆盖颜色变量（`[data-theme="light"]`），卡片、进度条、日志框、徽章都跟着变，结构没动。
- 结构是特意留好的：以后加「切换语言」「设置」等，**不用改 CSS / HTML**，在 `dashboard.html` 末尾调
  `window.panelDock.add({ id, icon, label, tip, onClick, pressed })` 即可，新按钮会自动叠在主题按钮上方
  （容器是 `flex-direction: column-reverse`，主题按钮永远在最下面）。

> 注意：这个工具坞在**本地面板 7788** 上。服务器上的 qq-bridge 控制台（`:3100`）没有它，保持原样。

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

- `key` 相对 `panel\` 目录，也可以用绝对路径；文件名不限（`id_ed25519`、`_yzxmm.pem` 都行）。
- 启动脚本的私钥检查也读这里（`key-path.cjs`），所以换私钥只改 `panel.config.json`，不用动 `.cmd`。
- 换服务器只改 `host` / `user` / `key` / `consoleToken`。
- `forwards` 是 `[本地端口, 服务器端口]` 的数组；面板的入口按钮和端口标签会自动跟着它变，改完重启面板即可。
- 本地端口被占（比如 3100 已有别的程序）就改 `forwards` 左边的数，比如 `[13100, 3100]`。

## 出问题先看这些

| 现象 | 原因 / 处理 |
| --- | --- |
| 窗口一闪而过 | 装了 Node 却没在 PATH 里，或 `panel.config.json` 的 `key` 指向的私钥不存在；脚本会停住并打印实际路径 |
| 桌面快捷方式没生成 | 现在由 `make-shortcut.vbs`（cscript）生成，失败才退到 `make-shortcut.ps1`。旧版失败是因为用户名带 `'`（如 `<你的用户名>`）会截断内联 PowerShell 的单引号字符串，已规避。彻底不行就手动：右键 `启动管理面板.cmd` → 发送到 → 桌面快捷方式 |
| `UNPROTECTED PRIVATE KEY FILE` | 私钥权限太宽。修：`icacls "<panel.config.json 里 key 的绝对路径>" /inheritance:r /grant:r "%USERNAME%:(R)"`（需管理员或对该文件有改权限） |
| 面板显示"隧道已断开（自动重连）" | 服务器 SSH 断了 / 网络抖动；它会 2s→30s 退避重连。看窗口日志 |
| 服务状态全红 | 服务器上 systemd 服务停了：`ssh` 进去 `systemctl status qq-bridge dsh-web` |
| noVNC 密码不对 | 容器重建后会随机换密码：`docker logs snowluma 2>&1 | grep -i "remote desktop password"`，同步改 `panel.config.json` 的 `vncPassword` |
| 日志一片空白 | 该服务确实没输出；换另一个 tab 看 |
| 点「服务器 DSH」还是 401 | `dsh-web` 从没启动过（日志里没有 `dsh web: http` 那行），或日志被清了：`journalctl -u dsh-web --no-pager | grep 'dsh web: http' | tail -1` 手动看一眼 |
| 数值看着不动 | 先看标题右侧的「更新于 … · xs 前」：秒数在走说明轮询正常，只是数据没变；点「立即刷新」可绕过 4 秒缓存强制重读 |

隧道日志和 ssh 的原始报错在 `deploy\panel\run\tunnel.log`（自动生成）。

## 面板接口（自己写脚本时有用）

| 接口 | 说明 |
| --- | --- |
| `GET /api/status` | 全部状态，服务端缓存 4 秒 |
| `GET /api/status?fresh=1` | 同上但绕过缓存（「立即刷新」按钮用它） |
| `GET /api/logs?src=bridge\|snowluma\|sl-app\|dsh&n=300` | 日志，缓存 2 秒，n 限 20~800 |
| `GET /api/dsh-token` | 从 `journalctl -u dsh-web` 里取当前 DSH 登录 token（缓存 5 秒） |
| `GET /api/avatar?uin=<QQ>` | 转取机器人头像（服务器侧代取腾讯图床，成功时 `cache-control: public, max-age=3600`） |
| `GET /api/config` | 面板配置里对前端可见的字段（consoleToken / vncPassword / 端口映射） |

> 说明：DSH 的登录链接是 `http://127.0.0.1:3080/?token=<43 位>`，用一次就换成 cookie，之后直接开 3380 即可。token 每次重启 `dsh-web` 都会变，所以面板不把它写进配置，而是点击时现取。
>
> 头像：机器人卡片的头像是 `GET /api/avatar?uin=<QQ>` 转出来的（服务端拿一次、缓存 1 小时）。前端把 `?t=<小时>` 拼进 URL，所以换了头像最多 1 小时自动刷到新的；拉不到时退回 🐟 图标，不会留破图。机器人昵称/群名称都带 `no_cache` 现取（SnowLuma 默认返回进程启动时的缓存，群改名、新人进群都不会反映，见下方故障表）。
