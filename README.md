<p align="center">
  <img src="macOS/README.assets/cover.webp" alt="清澈海水下的珊瑚礁" width="100%">
</p>

<p align="center">
  <img src="macOS/README.assets/icon.png" alt="Luqri 图标" width="88" height="88">
</p>

<h1 align="center">Luqri</h1>

<p align="center">一款轻量级原生多平台识别翻译工具</p>

<p align="center">
  <a href="#下载安装">下载安装</a> · <a href="#服务供应商">服务配置</a> · <a href="#开发">开发</a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-2f745f?style=flat-square" alt="许可证：MIT"></a>
  <a href="#平台"><img src="https://img.shields.io/badge/Platform-macOS%20%7C%20Windows-426b80?style=flat-square" alt="平台：macOS 和 Windows"></a>
  <a href="https://github.com/TermiQue/luqri/releases"><img src="https://img.shields.io/github/v/release/TermiQue/luqri?style=flat-square" alt="最新版本"></a>
</p>

---

## 详细介绍

Luqri 用来在当前应用里翻译和提取文字。阅读网页、文档或聊天时，选中文字后按快捷键即可打开翻译浮窗。遇到无法直接复制的文字，可以框选屏幕区域，将识别结果进行翻译或复制到剪贴板。浮窗也支持手动输入和翻译剪贴板内容。

应用平时运行在 macOS 菜单栏或 Windows 托盘中，翻译浮窗和截图界面按需打开。两端沿用相同的操作方式，并使用各自平台的窗口、快捷键和截图接口。

## 功能特性

- **划词翻译：**选中文字后直接查看译文，也可在浮窗中输入或粘贴原文。
- **截图 OCR：**框选屏幕区域，识别文字并复制到剪贴板。
- **截图翻译：**框选后在浮窗中同时显示识别出的原文和译文。
- **云端用量：**在设置中查看翻译和 OCR 用量。

## 截图

<table>
  <thead>
    <tr>
      <th scope="col" width="50%">macOS</th>
      <th scope="col" width="50%">Windows</th>
    </tr>
  </thead>
  <tbody>
    <tr><th colspan="2">翻译框</th></tr>
    <tr>
      <td align="center" valign="top"><img src="macOS/README.assets/translate.png" alt="macOS 翻译浮窗显示火山引擎和阿里云的译文" width="420"></td>
      <td align="center" valign="top"><img src="Windows/README.assets/translate.png" alt="Windows 翻译框" width="420"></td>
    </tr>
    <tr><th colspan="2">设置</th></tr>
    <tr>
      <td align="center" valign="top"><img src="macOS/README.assets/setting.png" alt="macOS 设置窗口中的翻译服务、OCR 服务和访问密钥" width="420"></td>
      <td align="center" valign="top"><img src="Windows/README.assets/setting.png" alt="Windows 设置窗口" width="420"></td>
    </tr>
    <tr><th colspan="2">截图</th></tr>
    <tr>
      <td align="center" valign="top"><img src="macOS/README.assets/ocr.png" alt="macOS 截图 OCR 在 GitHub 页面中框选文字" width="420"></td>
      <td align="center" valign="top"><img src="Windows/README.assets/ocr.png" alt="Windows 截图 OCR 框选界面" width="420"></td>
    </tr>
  </tbody>
</table>

## 快速开始

### 下载安装

从 [GitHub Releases](https://github.com/TermiQue/luqri/releases) 下载对应的安装包。

- **macOS**。打开通用 DMG，将 Luqri 拖入「应用程序」后启动。设置可从菜单栏打开。首次使用划词时，在「隐私与安全」授予「设备控制和数据访问」或「辅助功能」权限。截图则使用「录屏与系统录音」列表。`-adhoc.dmg` 为临时签名的本地测试包。
- **Windows**。按处理器架构选择 x64 或 ARM64 安装包。安装包自带 .NET 桌面运行时。启动后左键点击通知区域的 Luqri 图标即可打开设置。

| 操作 | macOS | Windows |
| --- | --- | --- |
| 划词翻译 | `⌥D` | `Alt+D` |
| 截图 OCR | `⌥W` | `Alt+W` |
| 截图翻译 | `⌥S` | `Alt+S` |

三个全局快捷键均可在设置中修改。macOS 15.0 和 15.1 若无法注册仅含 Option 的组合，可加入 Command 或 Control。 [Apple 开发者论坛说明](https://developer.apple.com/forums/thread/763878)

### 服务供应商

macOS 默认使用 Apple 翻译和 Apple Vision，Windows 默认使用火山引擎。翻译可同时启用多个服务，OCR 单独选择一个服务。云端翻译会把待译文字发送给所选服务，云端 OCR 会发送框选的截图。

下表列出 Luqri 用于检查云端用量的免费额度。实际免费余额以服务商控制台为准。

| 服务     | 阿里云        | 火山引擎      |
| -------- | ------------- | ------------- |
| 机器翻译 | 100 万字符/月 | 200 万字符/月 |
| OCR 识别 | 200 次/月     | 5,000 次（累计） |

#### 火山引擎

共需要开通 2 项服务，创建 1 个用户并赋予 4 项权限。

1. [机器翻译](https://console.volcengine.com/translate)

   ![在火山引擎控制台购买并开通机器翻译](README/volcengine-translation.png)

2. [多语种 OCR](https://console.volcengine.com/ai/ability/info/78)

   ![在火山引擎控制台完成实名认证并开通多语种 OCR](README/volcengine-ocr.png)

3. [创建用户](https://console.volcengine.com/iam/identitymanage/user)

   ![在火山引擎访问控制的用户列表中新建用户](README/volcengine-users.png)

   ![在火山引擎选择通过用户名创建](README/volcengine-user-creation-method.png)

   ![填写火山引擎用户名并勾选编程访问](README/volcengine-user-programmatic-access.png)

4. 为用户添加四项权限策略。`TranslateFullAccess` 对应机器翻译，`CVFullAccess` 对应智能视觉，`BillingCenterReadOnlyAccess` 对应费用中心，`CloudTrailReadOnlyAccess` 对应操作审计。

   ![为火山引擎用户直接添加四项权限策略](README/volcengine-user-permissions.png)

5. 在用户详情的「密钥」页创建访问密钥。回到 Luqri 设置，在「访问密钥」中选择火山引擎并保存。翻译用量查询需要 `ListBillDetail` 权限，OCR 累计用量通过 `LookupEvents` 核对。

   ![在火山引擎用户详情中创建 Access Key](README/volcengine-user-access-keys.png)

#### 阿里云

开通机器翻译通用版和 OCR 统一识别服务后，创建一个 RAM 用户并添加相应权限策略。

1. [机器翻译](https://mt.console.aliyun.com/service)

   ![在阿里云控制台开通机器翻译通用版](README/aliyun-translation.png)

2. [文字识别](https://ocr.console.aliyun.com/overview)

   ![在阿里云控制台的服务管理与开通页面开通 OCR](README/aliyun-ocr.png)

3. [创建用户](https://ram.console.aliyun.com/users)

   ![在阿里云 RAM 用户列表中新建用户](README/aliyun-ram-users.png)

   ![填写阿里云 RAM 用户信息并选择 AccessKey 访问](README/aliyun-ram-programmatic-access.png)

4. 授予翻译 `alimt:TranslateGeneral`、OCR `ocr:RecognizeAllText` 和用量查询所需的 `alimt:GetTranslateReport`、`actiontrail:LookupEvents` 权限。

   ![阿里云 RAM 用户的机器翻译、文字识别和操作审计权限策略](README/aliyun-ram-permissions.png)

5. 创建完成后保存页面显示的 AccessKey。在 Luqri 设置的「访问密钥」中选择阿里云，填入并保存。

## 项目架构

```text
macOS/
  Luqri/                 Swift 源码与原生资源
  Luqri.xcodeproj/        Xcode 工程
  scripts/               构建应用、生成 DMG 与公证
Windows/
  Luqri.Windows.csproj    WPF 工程，源码与资源位于同一目录
  Luqri.iss               Inno Setup 安装定义
  scripts/               构建应用与安装程序
```

两端分别实现选区读取、截图、窗口和服务调用。划词翻译先读取文本选区，再把结果送入翻译浮窗。截图 OCR 与截图翻译复用同一条识别流程，识别结果分别送入剪贴板或翻译浮窗。

## 技术栈

| 平台 | 界面与系统集成 | 翻译、识别与朗读 |
| --- | --- | --- |
| macOS | Swift、SwiftUI、AppKit、ScreenCaptureKit | Apple Translation、Vision、AVFoundation、火山引擎和阿里云 API |
| Windows | C#、.NET 10、WPF、Win32、Windows UI Automation | 火山引擎和阿里云 API、System.Speech |

## 平台

| 平台 | 系统要求与架构 | 源码 |
| --- | --- | --- |
| macOS | macOS 15.0 及以上 · Apple Silicon、Intel | [macOS](macOS/) |
| Windows | 支持 .NET 10 的 Windows 系统 · x64、ARM64 | [Windows](Windows/) · [.NET 系统要求](https://learn.microsoft.com/zh-cn/dotnet/core/install/windows) |

## 开发

**macOS** 使用 Xcode 16.3 或更新版本。可在 Xcode 中打开 `macOS/Luqri.xcodeproj`，也可在仓库根目录运行以下命令。

```sh
cd macOS
./scripts/build.sh
open .build/Luqri.app
./scripts/package.sh --local  # 生成通用 DMG 与 SHA-256 文件
```

正式分发时，设置 `LUQRI_SIGN_IDENTITY` 和 `LUQRI_NOTARY_PROFILE` 后运行 `./scripts/package.sh`，使用 Developer ID 签名并提交 Apple 公证。

**Windows** 使用 .NET 10 SDK。构建脚本默认生成 x64 与 ARM64 的自包含版本。打包安装程序需要 Inno Setup 7.1 或更新版本。

```powershell
Set-Location Windows
.\scripts\build-windows.ps1
.\scripts\package-windows.ps1
```

两端产物分别写入 `macOS/.build/` 和 `Windows/.build/`。

## 许可证

Luqri 采用 [MIT 许可证](LICENSE)。[macOS 的 Lucide 许可证](macOS/Luqri/Lucide-LICENSE.txt) · [Windows 的 Lucide 许可证](Windows/Lucide-LICENSE.txt)
