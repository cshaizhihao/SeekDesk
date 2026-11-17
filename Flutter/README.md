# SeekDesk Flutter

SeekDesk 的 Flutter 界面重构工程。界面使用官方
[`liquid_glass_widgets` 1.17.3](https://github.com/sdegenaar/liquid_glass_widgets)，
通过 Impeller 在 macOS 上运行真实的玻璃着色器、折射和交互动画。
依赖固定在 `../Vendor/liquid_glass_widgets`，保留官方渲染器和着色器，并对可滚动
标签的动态几何更新做局部修正；原始文件哈希、许可证和补丁说明随源码保留。

V1.5.1（构建 72）使用此 Flutter 客户端。
经明确授权的本机交付使用 `/Applications/SeekDesk.app` 和原有
`com.seekdesk.client` 标识，连接真实 Swift 业务服务并保留账号与设置。
普通开发构建仍使用独立的预览标识；两种构建方式见下文，不能互换安装。

本次重构已接入原有主要任务链：三栏阅读与搜索、标签恢复、阅读位置保存、
NQ/TQ 报告缩放、图片查看器、Markdown 编辑、通知与私信、个人空间、设置及
扩展管理。界面不会用演示帖子或虚构登录状态替代真实服务。验收区分自动化
检查、联网只读操作和用户实际输入体验；编译成功或静态截图不代表所有交互
已经实机验证，也不代表论坛写入流程已经实际提交。

## 工程结构

- `lib/`：Flutter 界面、导航、阅读与编辑状态，以及原生通道客户端。
- `macos/`：Flutter 官方标准 Xcode Runner，应用入口为 `FlutterHostDelegate`。
- `macos/Runner/NativeBridge/`：Swift 方法通道与事件通道，向 Flutter 提供业务服务。
- `../Sources/SeekDesk/`：复用原客户端的 Swift 业务、论坛解析、代理和持久化代码，
  通过 Xcode 同步目录加入同一 `Runner` 模块。
- `scripts/`：统一 Flutter 环境、原生依赖准备与本机构建脚本。
- `test/`：Dart 状态、数据契约和界面验证。

Flutter 负责界面绘制与交互。论坛请求、账号 Cookie、图片请求和专用代理继续由
原生服务管理。Flutter 不自行建立绕过原生代理配置的论坛 HTTP 通道。
通道结构与方法见 [`native_contract.md`](lib/core/native_contract.md)。

## 本机开发

当前目标是 Apple Silicon macOS。需要完整 Xcode，以及 Flutter 3.50 / Dart 3.14
或兼容版本。此 Mac 已安装 Xcode 27.2 与官方 Metal Toolchain，固定的 Flutter
3.50.0 SDK 位于项目根目录下的 `.tools/flutter`。SDK、包缓存和 Flutter 配置均在
被 Git 忽略的 `.tools/` 中。

在此目录使用统一脚本运行命令：

```sh
bash scripts/flutter.sh --version
bash scripts/flutter.sh pub get
bash scripts/flutter.sh analyze
bash scripts/flutter.sh test
bash scripts/build-macos.sh debug
```

使用 `profile` 或 `release` 可编译优化版本：

```sh
SEEKDESK_PUB_OFFLINE=1 bash scripts/build-macos.sh release
```

需要采集本机帧耗时时，可显式构建性能测试版本：

```sh
SEEKDESK_PUB_OFFLINE=1 bash scripts/build-macos.sh profile \
  --dart-define=SEEKDESK_PROFILE_FRAMES=true \
  --dart-define=SEEKDESK_PROFILE_OUTPUT=/absolute/path/to/frame-profile.jsonl
```

普通构建不采集帧数据；性能测试会记录当前渲染能力、显示刷新率及帧耗时窗口。
单元和控件测试使用最小玻璃质量，以便隔离业务逻辑，不能替代真机 Premium
折射、动画和滚动性能验收。

### 可选的开发性能夹具

本次本机交付与交互验收直接使用联网客户端。下面保留的是供开发者独立复现
渲染问题的工具，不属于日常安装包，也不能替代真实客户端验收。

`tool/profile_reader.dart` 是独立的本机 A/B 测试入口，不会由正常入口导入。
它复用实际 `WorkspaceScreen`、`ReaderScreen`、Markdown/终端组件及 iOS 27
玻璃主题，使用固定的 250 行 NQ 样式终端、25 条回复和内存状态。
所有按钮请求都由内存客户端处理或拒绝，不向论坛或图片服务器发送请求。
启动时回到相同位置；设置与阅读位置不会写入磁盘。

必须通过以下显式路径构建，脚本会自动固定 Dart 入口与原生隔离标志：

```sh
SEEKDESK_PROFILE_FIXTURE=1 SEEKDESK_PUB_OFFLINE=1 \
  bash scripts/build-macos.sh profile \
  --dart-define=SEEKDESK_PROFILE_FRAMES=true \
  --dart-define=SEEKDESK_SHARED_BACKDROP=false \
  --dart-define=SEEKDESK_PROFILE_OUTPUT=/absolute/path/to/fixture-backdrop-off.jsonl
```

对照版本将 `SEEKDESK_SHARED_BACKDROP` 改为 `true`，并使用另一个日志路径。
不要再传 `--target`；脚本拒绝覆盖夹具入口、Release 或本机交付模式的组合。
产物为 `build/macos/Build/Products/Profile/SeekDesk Benchmark.app`，标识为
`com.seekdesk.flutter-benchmark`。Swift 的 `SEEKDESK_PROFILE_FIXTURE` 编译分支
完全跳过业务 bridge/context、账号存储、代理控制器、通知和更新服务，仅保留
关闭窗口所需的 `lifecycle.flush` 握手。该临时 QA 应用不应安装或发布。

两次运行使用相同显示器、刷新率、窗口大小及固定滚轮轨迹，先执行相同预热动作，
再比较三轮相同交互的区间 `raster.p95ms`、最大值及 `overRefreshBudgetPercent`。
日志中的 `localSyntheticFixture: true` 标识合成数据；`startupFrames` 单列首 10 帧，
`intervalAfterFirst10Frames` 排除这些帧，`rolling` 是独立滚动统计。闲置时不输出
重复旧帧，`totalSpan` 含调度与排队，不能全部解释为 GPU 时间。

夹具数据与入口编译检查（不构建 macOS 应用）：

```sh
bash scripts/flutter.sh analyze tool/profile_reader.dart test/profile_reader_fixture_test.dart
bash scripts/flutter.sh test --no-pub test/profile_reader_fixture_test.dart
```

离线模式需要依赖已在本机缓存。若使用其他 SDK，可通过
`SEEKDESK_FLUTTER_SDK=/absolute/path/to/flutter-sdk` 指定；无需修改系统 PATH。
构建脚本会准备固定版本的 Sparkle、编译标准 macOS Runner，并校验本地应用的
签名、Info.plist 与预览版标识。脚本不会安装、启动或上传应用。

构建产物位于：

```text
build/macos/Build/Products/Debug/SeekDesk Flutter.app
build/macos/Build/Products/Profile/SeekDesk Flutter.app
build/macos/Build/Products/Release/SeekDesk Flutter.app
```

原生依赖、资源打包和更多构建说明见 [`macos/BUILDING.md`](macos/BUILDING.md)。

通过本机交互验收后，使用显式的本机交付脚本准备保留原账号数据的安装包：

```sh
SEEKDESK_PUB_OFFLINE=1 bash scripts/build-local-macos.sh
```

该命令只构建 Release，使用原有 `SeekDesk` 应用名、`com.seekdesk.client` 标识和
品牌图标，并验证版本文件后输出到仓库 `dist/SeekDesk.app`。它不会启动、安装或
发布。最终本机替换由仓库的 `scripts/install-local.sh` 完成；替换前需要正常退出
正在运行的客户端并保留备份。默认 Debug、Profile、Release 构建仍使用隔离预览标识。

## 构建标识与数据保护

默认预览构建使用 `com.seekdesk.flutter-preview`，与本机交付客户端
`com.seekdesk.client` 分开。UserDefaults、默认 WebKit 网站数据，以及代理节点和
图床密钥的钥匙串服务名均使用预览版存储。此工程不会自动迁移原客户端账号数据。
显式的 `build-local-macos.sh` 则保留原有标识及存储，不进行预览数据导入。
安装时应先核验包、正常退出应用、备份当前偏好，再运行仓库安装脚本；不要用
旧备份覆盖用户的新草稿、阅读位置或账号状态。

正式构建的版本和构建号应与根目录的 `VERSION`、`BUILD_NUMBER` 一致。
发布时从同一已验证的应用生成 DMG、SHA-256、Sparkle ZIP 和 `appcast.xml`。

关闭窗口或退出应用前，Runner 会通过 `lifecycle.flush` 等待本地发帖、回复、私信
草稿保存。尚未提交的楼层或个人资料修改会阻止退出，保留窗口供用户保存或放弃；
退出过程不会自动提交任何服务器编辑。握手失败或超时也会保留窗口。预览版禁用
Sparkle 更新检查，避免下载并覆盖成原正式客户端。系统关键词通知只注册投递与
点击处理，启动时不会自行申请通知权限。

## 验证范围

验证记录位于仓库 `audits/flutter-migration-2026-11-14/`。本次计划以第 72 轮
收官，逐项范围及实际结果以该轮最终记录为准；历史报告中的待办要结合后续
修复记录阅读，不能重复当作当前缺陷。

- Flutter 自动化覆盖状态、界面、布局、文字选择、编辑器、路由归属及阅读恢复；
  原生检查覆盖桥接、解析、代理、媒体处理和持久化的受控接口。
- 普通 Release 编译掉可选诊断。性能日志记录的是 Flutter 引擎耗时，不是
  显示器实际呈现帧率，也不能仅凭组件测试推断真实玻璃着色器的性能。
- 本机联网验收只操作允许的只读路径，不自动发帖、评论、点赞、发私信、上传
  图片、保存个人资料或消费真实未读。对应写入分支使用注入的本地测试接口。
- 真实代理连通性及物理鼠标、触控板、中文输入法的手感由用户实机确认。
  自动化输入与截图不代替这些体验结论。

发现加载失败时应保留准确错误、重试入口和已有内容，不以伪造数据掩盖失败。

## 开源与许可

SeekDesk 源码遵循仓库根目录的 [`GPL-3.0-only`](../LICENSE)。Flutter 框架、
Dart 包与原生依赖保留各自许可。

- 玻璃组件：`liquid_glass_widgets` 1.17.3，Sebastian Degenaar，MIT。
- 其内置渲染基础和弹簧动画：`liquid_glass_renderer` 与 `motor`，Tim Lehmann，MIT。
- Cupertino 图标：`cupertino_icons` 1.0.8，MIT。
- Markdown 解析：`markdown` 7.3.0，BSD。

完整版权与许可声明见 [`THIRD_PARTY_NOTICES`](THIRD_PARTY_NOTICES)，构建时也会
复制到应用资源中。Flutter 自动生成的完整运行时 Dart 包许可保存在
`App.framework/Resources/flutter_assets/NOTICES.Z`；Sparkle、Yams、libyaml 与
Xray 的许可会分别打包到 `Contents/Resources`。

SeekDesk 是独立开发的第三方客户端，与 NodeSeek 官方没有隶属关系。帖子内容、
账号权限和社区规则均以 [NodeSeek](https://www.nodeseek.com/) 为准。
