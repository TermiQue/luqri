# <img src="macOS/README.assets/icon.png" width="48" height="48" alt=""> Luqri

Luqri 是 macOS 菜单栏和 Windows 托盘中的翻译与文字识别工具，支持划词翻译、截图 OCR 和截图翻译。

| 平台 | 使用与开发文档 |
| --- | --- |
| macOS | [安装、快捷键、系统权限、构建与打包](macOS/README.md) |
| Windows | [安装、快捷键、构建与打包](Windows/README.md) |

各端的源码、截图和构建脚本位于对应的平台目录。已发布的安装包见 [GitHub Releases](https://github.com/TermiQue/luqri/releases)。

## 配置火山引擎

1. 登录火山引擎，根据需要开通文本翻译、多语种 OCR，或同时开通两项。 [机器翻译开通与计费](https://docs.volcengine.com/docs/machine-translation/product-billing) · [多语种 OCR 开通与计费](https://docs.volcengine.com/docs/large-model-of-image-generation/ability-to-introduce-1)
2. 在火山引擎访问控制控制台的「资源管理 → 密钥管理」创建访问密钥，获取 `Access Key ID` 和 `Secret Access Key`。所用账号需要有权调用已开通的服务。 [访问控制控制台](https://console.volcengine.com/iam) · [获取访问密钥](https://docs.volcengine.com/docs/cp/signature-mechanism?lang=zh)
3. 打开 Luqri 设置，在「火山引擎」中填写这两个字段并点击「保存密钥」，再启用火山引擎翻译。macOS 使用云端截图识别时，还需在「OCR 服务」中选择火山引擎。Windows 的截图识别使用火山引擎多语种 OCR。

启用火山引擎翻译后，待译文字会发送给火山引擎。使用火山引擎 OCR 时，框选的截图会发送给该服务。截图翻译会将识别出的文字交给已启用的翻译服务。

设置中的用量环显示本月已入账的文本翻译字符数。查询需要当前密钥有权调用费用中心的 `ListBillDetail` 接口。 [账单管理 API](https://docs.volcengine.com/docs/billing-center/openapi-interface-list?lang=zh)

## 语言

原文语言和译文语言可以在设置中修改。译文语言设为「自动选择」时，中文原文译为英语，其余原文译为简体中文。
