# 构建与发行

## 版本

`VERSION` 是三段版本号，`BUILD_NUMBER` 是递增的内部构建号。发行前同步更新 `Flutter/pubspec.yaml` 和 `Distribution/Info.plist`，并在 `docs/releases/` 添加对应的版本说明。

## 当前 Flutter 版本

```sh
bash Flutter/scripts/flutter.sh pub get
bash Flutter/scripts/flutter.sh analyze
bash Flutter/scripts/flutter.sh test
bash Flutter/scripts/build-local-macos.sh
bash Flutter/scripts/package-update.sh
```

使用经过签名结构校验的 `dist/SeekDesk.app` 制作 DMG，在卷内放置应用和指向 `/Applications` 的链接。校验 DMG 并生成同名的 `.sha256` 文件。同一 GitHub Release 应包含 DMG、SHA-256 文件、更新 ZIP 和 `appcast.xml`。确认四项资产完整后再公开发布。

## 独立 SwiftUI 版本

```sh
./scripts/test.sh
bash scripts/test-regressions.sh
swift build --arch arm64 -c release
./scripts/build.sh unsigned
```

`unsigned` 使用临时 ad hoc 签名维持包结构完整性，文件名包含 `-unsigned`，不代表 Developer ID 签名或 Apple 公证。V1.0.0 采用此模式。`preview` 使用相同本地签名方式，文件名包含 `-preview`，用于开发验证。

所有模式都校验应用签名结构、创建并验证 DMG，再写入 `dist/` 和配套 SHA-256 校验文件。仅在完整打包验证通过后替换原有 app。公开发行上传最终 DMG 和校验文件到同一版本的 GitHub Release。

## Developer ID 签名和 Apple 公证

准备 Apple Developer Program 会员、安装在钥匙串中的 Developer ID Application 证书及私钥，并用 `notarytool store-credentials` 在钥匙串中配置公证 profile。请交互输入凭据，不把私钥、密码、API key 或证书导出包写进仓库。

```sh
export SEEKDESK_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export SEEKDESK_NOTARY_PROFILE='SeekDesk-notary'
./scripts/build.sh release
```

此模式为内嵌可执行组件逐个签名，启用 Hardened Runtime 与安全时间戳，提交 DMG 公证，附加票据并执行校验。手动更新的公证版不要求配置 Sparkle feed。发布前还应验证下载后的首次打开、应用替换、会话和本机数据恢复。

## 应用内更新

独立 SwiftUI 打包脚本的 `release` 模式可通过 `SEEKDESK_FEED_URL` 与 `SEEKDESK_UPDATE_PUBLIC_KEY` 单独配置 Sparkle。Flutter 正式构建自 V1.5.0 起使用仓库的 GitHub Release 更新源。

已发布的 V1.0.0 需要手动安装一次含有更新功能的 Flutter 版本。后续更新使用 GitHub Release 内的 `appcast.xml` 和经过 Ed25519 签名的 ZIP。应用包仍可使用临时签名。

构建发行用 Flutter 版本后，运行 `bash Flutter/scripts/package-update.sh`。脚本从发布机的私有密钥文件签名，默认读取 `~/.config/seekdesk/update-signing.key`，也可以用 `SEEKDESK_UPDATE_SIGNING_KEY_FILE` 指定路径。私钥只保留在发行环境，应用内只包含公钥。每次发行须提升构建号，将 `SeekDesk-版本号-macOS-update.zip` 和 `appcast.xml` 连同原有安装包上传到同一个 GitHub Release，上传完整后再公开该发布。

参考：[Apple Developer ID](https://developer.apple.com/developer-id/)、[Apple 公证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、[Sparkle 发行](https://sparkle-project.org/documentation/publishing/)。
