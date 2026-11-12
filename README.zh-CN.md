# TouchBarEnhancer

[English](README.md) · 简体中文

原生 macOS 菜单栏应用，用可复用组件为不同 App 定义 Touch Bar。使用 Swift 与 AppKit 开发，无需 BetterTouchTool，也无需安装完整 Xcode。

**项目状态：** 开发初期，当前版本为 0.2.0。最低支持 macOS 14，实体使用需要配备 Touch Bar 的 MacBook Pro。应用界面使用英文。

## 功能

- 通过苹果原生 **Customize Touch Bar…** 拖放面板，为每个 App 单独排列组件。
- 所有 App 均可使用 **Keyboard Shortcuts（快捷键）**、**Quick Phrases（常用语）**、**Text（文字）**；兼容的 ChatGPT/Codex 版本另有专属控件。
- 支持左对齐、居中、右对齐的 **Scrolling（滚动式）**，以及逐项设置 Relative、Fixed、Hug 宽度的 **Fill（铺满式）**。多个自适应组件平分剩余空间。
- 组件和单个按钮可分别设置 **Icon Only** / **Icon + Text**；按钮使用普通原生文本，空间不足时显示末尾省略号。
- 即时编辑、列表拖动排序、按 App 独立保存配置，无需点击 Save。
- 支持勾选模式、排除模式、单个 App 强制覆盖及全局暂停，默认静默启动。
- 保留系统 Control Strip，以首个组件替代模态栏最左侧的关闭位置。
- 在 Control Strip 设置页自定义独立按钮的 SF Symbol、点按／长按／修饰键动作，以及蓝牙／系统媒体播放自动化；使用私有注册接口，位置由 macOS 管理。

## 构建与运行

### 下载

从 [GitHub Releases](https://github.com/in4pira10n/TouchBarEnhancer/releases/latest) 下载 Apple Silicon（`arm64`）ZIP，解压后将 `TouchBarEnhancer.app` 放在固定位置，再授予辅助功能权限。当前安装包要求 macOS 14+，采用本机签名，**尚未公证**，Gatekeeper 可能阻止打开。安装前请阅读发布说明。本次不包含 Intel 安装包。

### 环境要求

- macOS 14 或更新版本。
- 带有 Swift 6.0 或更新版本的 Xcode Command Line Tools；开发使用 Swift 6.0.3，无需完整 Xcode。
- 登录钥匙串内可用、在本机信任的固定代码签名证书及其私钥。

检查工具链：

```sh
xcode-select --install # 仅在尚未安装 Command Line Tools 时执行。
swift --version
xcrun --show-sdk-path
```

克隆仓库并编译：

```sh
git clone https://github.com/in4pira10n/TouchBarEnhancer.git
cd TouchBarEnhancer
swift build -c release
```

打包为可运行的 App 前，通过 `security find-identity -v -p codesigning` 查看可用签名身份。可使用已有开发证书，或通过“钥匙串访问”的“证书助理”创建本机 Code Signing 证书并配置信任。打包脚本不会自动创建证书。

```sh
export TOUCHBAR_SIGNING_IDENTITY="YOUR_CODE_SIGNING_IDENTITY"
bash scripts/build-app.sh
open -g dist/TouchBarEnhancer.app
```

也可将证书名称或指纹写在项目根目录 `.signing-identity.local` 的第一行。Git 已忽略此文件；请勿提交证书或私钥。

签名身份缺失或不可用时构建会失败，不会退回临时签名。更新时保持相同的证书、bundle ID 和安装路径，有助于保留辅助功能授权。重新打包前先退出当前 App，之后仍运行同一个 `dist/TouchBarEnhancer.app`。

## 配置 Touch Bar

1. 从菜单栏 **TB → Settings…** 打开设置。静默启动默认不会显示此窗口。
2. 在 **Applications** 选择 **Exclusion Mode**（勾选的 App 使用原生栏）或 **Selection Mode**（仅勾选的 App 使用自定义栏）。
3. 在 **Apps** 选择目标 App 并配置组件。勾选模式下，此列表与 Applications 一致，也包含未勾选的条目。
4. 点击 **Customize Touch Bar…**，拖入并排列组件。设置期间临时预览所选 App 的栏，离开预览后恢复正常规则。
5. 使用发送快捷键或控制 App 菜单的功能时，在 **系统设置 → 隐私与安全性 → 辅助功能** 中允许 TouchBarEnhancer。

`Auto` 遵循勾选/排除策略；显式 `Enabled`、`Native` 覆盖 Auto，全局暂停优先于所有规则。移除规则后恢复策略决定的 Auto。使用 **Hide and Restore System Bar** 收起当前栏，或用 **Show Touch Bar** 重新应用规则。

使用前暂停其他 Touch Bar 替换工具，避免多个工具争抢显示。

## 组件

**Settings → Control Strip** 配置系统栏入口，默认启用。可修改 SF Symbol，并选择点按动作：暂停／恢复增强（默认）、粘贴剪贴板、粘贴指定文本、复制文本、发送录制的快捷键、运行 Apple 快捷指令或打开 URL。修改立即保存并生效，Default 只重置图标。快捷指令可选择无输入、剪贴板文字或指定文字，通过 `/usr/bin/shortcuts` 在后台运行，参数不会交给 Shell 解释。粘贴剪贴板保留原内容，支持图片、文件；粘贴和快捷键动作操作当前前台 App，并要求辅助功能权限。指定文本粘贴后保留在剪贴板。失败信息显示在菜单栏图标的悬浮提示及已打开的此设置页中。

**Previous Media**（上一条媒体）和 **Next Media**（下一条媒体）向系统“正在播放”发送切换命令，可用于所有交互。无需切换 App、发送快捷键或更改剪贴板。是否支持切换、上一条是否先回到开头，由当前播放器决定；系统接受命令不等于播放器已完成切换。

左侧 **Configurations** 列表固定显示 Default 和自动化规则。选中 Default 编辑默认按钮；点击 **Add Rule** 从 Default 复制一条默认关闭的规则。右侧依次为规则名称与开关、**When all match**（全部条件满足）和 **Use this button**（使用的图标与点按动作）。条件可选 **Bluetooth device is connected**（蓝牙设备已连接）、**Music / media is playing**（音乐／媒体正在播放），或同时勾选。蓝牙条件先用 Refresh 选择已配对设备，再启用规则。首条命中的启用规则优先，可拖动或用 ↑／↓ 调整顺序。Default 不可移除或排序，没有规则命中时恢复它。顶部独立显示实际生效的配置，不随编辑选择切换。条件只切换配置，动作仍需点按触发，编辑实时保存。

每个配置（包括 Default）都有独立的 **Show button** 开关。关闭后，此配置生效时隐藏我们新增的 Control Strip 按钮，保留图标及动作，并继续检查自动化条件。隐藏的命中规则仍占据原优先级。例如，关闭 Default 的显示、开启播放规则的显示，即可只在播放时出现按钮。顶部 **Enable Control Strip button** 是按钮与自动化的总开关。旧配置升级后默认保持显示。

媒体条件使用系统“正在播放”通知：启用时读取一次初始状态，之后随播放／暂停及播放来源变化更新，不定时查询媒体。通过带可用性检查的私有 MediaRemote 接口，支持接入系统状态的音乐、视频及浏览器媒体，并非仅音乐；暂停或无法取得状态时不匹配。只有蓝牙条件在需要时约每两秒检查已配对设备的连接状态，不扫描或主动连接；macOS 可能请求蓝牙权限。配置隐藏按钮期间仍继续监听；不会启动媒体 App 或改变播放。没有启用且有效的规则时停止监听；仅使用媒体条件时不访问蓝牙，也不启动轮询定时器。

每个配置还可分别设置 **Tap**（点按）、**Long Press**（长按）、**Option + Tap**、**Command + Tap**、**Control + Tap**。选择 **Interaction** 后，使用同一组字段编辑该交互的动作。原有点按配置保留，新交互默认 **No Action**。在 Long Press 下可通过 **Hold for** 为各配置独立设置时长（0.1–10 秒，默认 0.6 秒），**Default** 恢复为 0.6 秒。长按仅触发一次，松手不再执行点按；修饰键按下状态在接触按钮时确定，Shift 或多个修饰键组合不执行动作。带修饰键长按仍在松手时执行对应点按。移出按钮、隐藏按钮或切换配置会取消尚未完成的按压。长按只有按住时的一次性计时，媒体监听继续采用事件通知。

按钮移除 App 风格的圆角边框，尺寸由系统栏分配。注册入口不会修改系统保存的按钮顺序，也不会移除播放按钮。具体位置和可用性取决于 macOS；关闭选项或正常退出会移除入口。暂停／恢复动作仍遵循 App 规则。

在本机 macOS 14.8.9 的实际截图中，入口位于展开箭头旁、系统按钮之前。将系统折叠栏的播放键标识替换为我们的标识，也未能将入口移至最右侧；测试配置已恢复。因此当前实现是新增入口，尚未实现原位替换播放键。若单独重启了系统 ControlStrip 进程，需重新启动 TouchBarEnhancer 恢复入口。

| 组件 | 行为 |
| --- | --- |
| Keyboard Shortcuts | 按 App 保存快捷键按钮，可定义图标、标题、可选背景色、快捷键及描述。在设置中直接录制组合键；清除背景色恢复通用灰色。 |
| Quick Phrases | 按 App 保存常用语，通过 Command+V 粘贴到当前聚焦的输入框。不发送 Return；粘贴后剪贴板保留该短语。 |
| Text | 按 App 保存文字条目，可调字体、字号、字重、颜色、字距、基线、对齐、装饰、截断及背景色。每个属性均有独立 Default。默认纯白文字、透明背景；添加背景后左右各留 4 pt 内边距。整个组件支持 Auto、Fixed、Hug 宽度。 |
| Chat Shortcuts | 自定义聊天标题、Symbol/图片、颜色及 Control+1–9 槽位，用于专属 ChatGPT 布局。 |
| Sidebar / Terminal | 通过目标 App 暴露的匹配菜单执行动作。Terminal 需要兼容的底部面板命令。 |
| Space | 原生弹性空间，由用户在自定面板中主动添加。 |

所有列表组件均支持 Scrolling 与 Fill。Fill 下可在表格的 **Width** 列逐项选择 **Relative**（相对权重，默认 12）、**Fixed**（点数）或 **Hug**（适应内容）。先扣除 Fixed/Hug 条目及间距，再按 Relative 权重分配剩余宽度；`6、6、12` 即 `1:1:2`，默认仍为均分。没有 Relative 条目时剩余空间留在尾部；Fixed/Hug 内容超宽时可以滚动。切换 Scrolling 后隐藏并忽略宽度设置，但保留其配置。按钮间距仍为 8 pt，组件间距仍为 12 pt。富文本样式仅用于 Text，普通操作按钮保留原生普通文本。

ChatGPT 适配依靠本机菜单和用户配置的快捷键，**不会获取或同步置顶聊天列表**，不读取聊天内容，也不需要 API Key。菜单可用性及 Control+数字的行为取决于目标 App 和版本，请按实际快捷键配置槽位。Music、Safari 当前使用通用组件，尚无专属适配。

Text 表格上方另有整个组件的 **Width** 设置，两种 Layout 下均可使用：**Auto** 保留原来的等分方式，**Fixed** 指定点数，**Hug** 适应整组文字内容。组件可收窄至小于 32 pt，并将释放的空间交给其他自适应组件。它独立于表格内每条文字的 Fill 宽度设置；间距及操作按钮的文字样式保持不变。

## 权限、数据与限制

- 配置通过 UserDefaults 与 AppKit 布局持久化保存在本机。用户导入的图片保存在配置中，不在此仓库内。
- 快捷键、常用语与 App 菜单控制需要辅助功能权限；被动展示及 Text 不需要。点击常用语会更新剪贴板。
- TouchBarEnhancer 不需要网络 API、账号登录或 API Key。
- 跨 App 展示使用 **私有系统模态 Touch Bar API**，封装在 `Sources/TouchBarBridge`。macOS 更新可能影响兼容性；选择子存在不等于硬件展示正常。
- 从原生栏重新切入自定义栏时，仍可能出现系统滑入动画，此问题尚未解决。
- 尚未实现登录时启动、公证及自动更新；发布产物采用本机签名。
- 休眠前会收起自定义栏，唤醒后如有需要可点击 **Show Touch Bar**。崩溃、强制退出或其他工具争用后的恢复仍需实机验证。

## 开发与验证

项目约定与适配设计规范见 [AGENTS.md](AGENTS.md)。

```sh
bash scripts/check-settings.sh
bash scripts/check-settings-ui.sh
bash scripts/check-component-layouts.sh
bash scripts/check-component-widths.sh
bash scripts/check-text-component.sh
bash scripts/check-native-customization.sh
swift build -c release
```

其他脚本覆盖按 App 独立常用语、显示覆盖、快捷键、拖动排序及静默启动。测试尽量使用隔离偏好和离屏视图。运行旧夹具前先检查代码，其中部分会显示交互界面。

完成签名打包后，可验证实体栏布局：

```sh
bash scripts/check-component-bar.sh
bash scripts/check-component-widths-bar.sh
bash scripts/check-text-region-width-bar.sh
bash scripts/check-control-strip.sh
bash scripts/capture-touchbar.sh
```

硬件检查会临时替换同一签名 App 内的可执行文件，结束后恢复正式版本并重新启动。截图由外部脚本执行，生成文件保存在 `.build/` 或 `dist/`；截图可验证绘制，不能证明实体触摸响应。

```text
Sources/TouchBarEnhancer/  生命周期、设置、组件及适配器
Sources/TouchBarBridge/    私有展示 API 的 Objective-C 封装
Resources/                应用元数据及内置图片
Tests/                    原生回归测试夹具
scripts/                  构建、签名、验证及截图工具
```
