# ChatGPT 额度仪表盘（macOS / Windows）

这是一个独立的桌面小工具，用仪表盘图标和文字直接显示 Codex 账户的两个限额窗口：

- 5 小时窗口剩余比例
- 7 天窗口剩余比例
- 两个窗口的预计重置倒计时
- 实时读取时间与数据来源标识

## Windows

Windows 版本保留 macOS 版本的额度读取、快照回退、详情弹窗和刷新菜单；macOS 菜单栏项目对应替换为 Windows 系统托盘 `NotifyIcon`。左键托盘图标显示/关闭详情，右键菜单可显示额度、立即刷新或退出；托盘悬停提示显示 5 小时与 7 天剩余比例。

当前可用的 Windows 安装包位于 `Windows/Packages/ChatGPT额度仪表盘.exe`。双击这个 `.exe` 后会按当前用户安装，不需要管理员权限，并创建桌面、开始菜单快捷方式和卸载项；安装器完成后立即退出，安装后的程序和快捷方式不通过 `cmd.exe` 启动。

## macOS

macOS 详情页采用内容优先的 Liquid Glass 布局：系统弹窗提供玻璃背景，刷新与关闭控件使用玻璃效果；两行额度直接排在内容层，通过细分隔线区分，显示剩余比例、重置时间和消耗速率，底部保留实时／快照状态。macOS 13–25 使用系统材质与标准按钮。支持系统深浅色、减少透明度和减少动态效果设置，⌘R 可刷新额度。

原有菜单栏项目和 Swift/AppKit 构建方式保持不变；可使用 `--show-details` 启动参数自动展开详情页。

## 启动

当前 macOS 安装包为 `Mac/Packages/ChatGPTQuotaPet-1.4-LiquidGlass.dmg`。打开磁盘映像后，将 `ChatGPTQuotaPet.app` 拖到 `Applications` 即可安装。

双击 `Mac/Codings/Start-ChatGPTQuotaPet.command`。首次运行会编译并打开 `Mac/Packages/ChatGPTQuotaPet.app`；之后也可以直接双击 `Mac/Packages/ChatGPTQuotaPet.app`。

状态栏会直接显示两行剩余额度：上面是 `5h 76%`，下面是 `7d 76%`，左侧为仪表盘图标。点击状态栏项目后，会在状态栏下方展开额度详情；点击外部或按 Esc 可关闭弹窗，右键状态栏项目可立即刷新或退出。

如果系统阻止 `.command` 或 `.app`，请在“系统设置 → 隐私与安全性”中允许打开，或先在终端执行：

```zsh
chmod +x ./Mac/Codings/Start-ChatGPTQuotaPet.command ./Mac/Codings/build-mac.sh
```

## 编译与自检

```zsh
./Mac/Codings/build-mac.sh
./Mac/Packages/ChatGPTQuotaPet.app/Contents/MacOS/ChatGPTQuotaPet --probe
```

`build-mac.sh` 会按当前 Mac 的 CPU 架构编译，并以 macOS 13.0 为最低兼容版本。自检只输出剩余比例、采样时间和来源，不输出原始会话内容。

## 数据来源与限制

程序优先通过本机 Codex `app-server` 的 `account/rateLimits/read` 接口读取实时额度，不读取 `auth.json`，不保存访问令牌。若本地接口暂时不可用，会自动回退到 `~/.codex/sessions/` 中最近的 `rate_limits` 快照，并在弹窗底部标记为“快照”。

此版本显示的是 Codex/ChatGPT 账户中 Codex 相关的 5 小时与 7 天限额，不是 ChatGPT 普通对话、语音或图片额度的统一总余额；额度数据仍以官方使用情况页面为准：

<https://learn.chatgpt.com/docs/pricing>

如果仍显示“暂时没有可用快照”，请确认 Codex 已登录并在 ChatGPT/Codex 中运行一次任务，再重新启动工具。
