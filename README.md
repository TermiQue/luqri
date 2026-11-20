# Luqri

Luqri 是 macOS 15.0+ 的原生菜单栏翻译与文字识别工具。使用 Swift、AppKit 和 SwiftUI，界面图标来自 Lucide。启动时只创建菜单栏图标和注册全局快捷键，翻译浮窗、截图及 OCR 按需运行。打开设置时，Luqri 会出现在 Dock 和应用切换器中。

## 构建

使用 Xcode 16 或较新版本打开 `Luqri.xcodeproj`，运行 `Luqri` scheme。也可以在仓库根目录执行以下命令。

```sh
xcodebuild -project Luqri.xcodeproj -scheme Luqri -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath .build/DerivedData build
open .build/DerivedData/Build/Products/Release/Luqri.app
```

如果本机的 Xcode 界面或 `xcodebuild` 尚未完成初始化，也可以通过 Swift 工具链构建当前架构的应用包。

```sh
./scripts/build.sh
open .build/Luqri.app
```

启动后点击菜单栏上的翻译图标。

## 使用

| 默认快捷键 | 操作 |
| --- | --- |
| `⌥D` | 翻译当前应用选中的文字。没有获取到选中文字时打开空白输入框。 |
| `⌥W` | 在一块显示器内拖动框选。识别成功后，将文字复制到剪贴板。 |
| `⌥S` | 框选后识别文字，在翻译浮窗中显示原文和译文。 |
| `↩` / `⌘↩` | 翻译当前输入。输入框内可用 `⇧↩` 换行。 |
| `Esc` | 取消截图、快捷键录制或关闭翻译浮窗或设置。 |
| `⌘,` | Luqri 在前台时，在当前屏幕居中打开设置。 |
| `⌘W` | 关闭当前设置窗口或翻译浮窗。 |
| `⌘M` | 将设置窗口最小化到 Dock。 |
| `⌘H` | 隐藏 Luqri。 |
| `⌘Q` | 退出 Luqri。 |

浮窗可置顶，也可复制原文和译文、分别折叠各服务的译文。点击原文或译文旁的扬声器可在本机朗读中文和英语。可在空白浮窗中输入或粘贴文字。全局快捷键可在设置中录制和恢复默认。截图 OCR 根据文本的行距和对齐位置合并明显的折行，支持保留列表与段落间距。

授权时，点击「前往授权」打开系统设置，按小窗提示拖入 Luqri 并开启开关。macOS 27.0–27.2 中，划词权限显示为「设备控制和数据访问」。截图请将 Luqri 拖到上方「录屏与系统录音」列表，旧版本 macOS 使用「屏幕与系统音频录制」名称。「仅系统录音」无法用于截图。

## 翻译服务

在设置里可单独开启 Apple 翻译和火山引擎。每次翻译会调用所有已开启的服务，并分别显示结果。

- **Apple 翻译**默认启用，使用 macOS Translation 框架。首次翻译时，系统可能会请求下载语言包。语言包就绪后可离线翻译。
- **火山引擎**需先开通机器翻译，再在 Luqri 的「设置」填写 Access Key ID 和 Secret Access Key，两个字段均可用 `⌘V` 或粘贴按钮填入。密钥存为本机的 `~/Library/Application Support/Luqri/volcengine.json`，文件权限为 `0600`。旧版保存在钥匙串中的密钥需要重新填写。火山引擎当前文本翻译每自然月前 200 万字符免费，超额按量计费。 [火山引擎计费文档](https://docs.volcengine.com/docs/machine-translation/product-billing)
- 默认自动选择译文语言。中文原文译为英语，其它语言译为简体中文。可在设置中指定原文语言和译文语言。

## OCR 服务

在设置的「OCR 服务」中单选 Apple Vision 或火山引擎多语种 OCR。截图识别和截图翻译共用这项设置。

- **Apple Vision** 默认在本机识别截图。
- **火山引擎多语种 OCR** 需要开通对应服务，并使用设置里保存的火山引擎访问密钥。应用会将所选截图发送给火山引擎进行识别。 [接口说明](https://docs.volcengine.com/docs/large-model-of-image-generation/calling-method-1)

## 图标

Luqri 使用 [Lucide](https://lucide.dev/) 的 SVG 图标，随应用打包。[Lucide 许可证](Luqri/Lucide-LICENSE.txt)
