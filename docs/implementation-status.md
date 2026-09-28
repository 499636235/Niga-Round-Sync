# Round Sync 二次开发实施状态

单一进度记录。规格见仓库根 `RoundSync_二次开发完整计划.md`，本文件只记"实际做了什么、实际跑过什么、结果是什么"。

最后更新：2026-09-28（P0 进行中）

## 0. 基线与工作区

| 项 | 实测值 |
|---|---|
| 仓库 | `D:/Development/AndroidStudioProjects/Niga-Round-Sync`，分支 `master` |
| HEAD | `bda00f8d0162acb30a343982c54e3426d2824c15` = 计划核查基线，无偏差 |
| 用户既有改动 | 仅 2 个未跟踪文档（计划 md + 启动提示词 txt），无代码改动，未做 reset/clean |
| app versionName / versionCode | 2.5.6 / 410（`app/build.gradle:20-21`） |
| 内置 rclone | 1.71.0（`gradle.properties`，构建产物版本串已实测为 `rclone 1.71.0`） |
| 构建强制依赖 | `app/build.gradle:135-137` 把 `preBuild` 接到 `:rclone:buildAll`：任何 app 任务都会交叉编译 4 个 ABI 的 `librclone.so`，所以 Go 与 NDK 是硬前置 |

## 1. 构建环境（本机实测）

| 组件 | 状态 | 位置 / 取值 |
|---|---|---|
| Gradle | 可用（8.12.1，仓库 wrapper） | 官方 `services.gradle.org` 重定向到 github.com，本机连不上；改从 `mirrors.cloud.tencent.com/gradle/` 取同名 zip，sha256 与 `services.gradle.org/…/gradle-8.12.1-bin.zip.sha256` 一致（`8d97a979…46c94`），放入 wrapper dists 目录 |
| JDK | JBR 21.0.8 | `D:\Program Files\Android\Android Studio\jbr`；`~/.gradle/gradle.properties` 已把 `org.gradle.java.home` 指到这里，与 Android Studio 同一个 daemon。系统 PATH 上是 JDK 8，命令行必须显式给 JAVA_HOME |
| Android SDK | `D:\ProgramFiles\Android\SDK` | 原本只有 platform 36；构建时 AGP 自动装好 platform 34（`licenses/android-sdk-license` 已存在，故许可自动接受） |
| Go | 1.24.13 已装 | `D:\Development\lib\go`，未改系统 PATH；sha256 与 go.dev 官方一致（`40b16bc8…459a`） |
| Go 网络 | `proxy.golang.org` 不通 | 已 `go env -w GOPROXY=https://goproxy.cn,direct`、`GOSUMDB=sum.golang.google.cn`、`GOCACHE=D:/Development/lib/gocache`（C 盘只剩 28G） |
| rclone 模块 | 已预取 | `rclone/cache/`（GOPATH 也在 cache 内，由 `rclone/build.gradle` 决定）；`go.mod` 里 `github.com/rclone/rclone v1.71.0` |
| NDK 25.2.9519653 | **缺失 → 基线 APK 打不出来** | SDK 下没有 `ndk/25.2.9519653`，且 SDK 无 `cmdline-tools`，`rclone/build.gradle:62-92` 的自动安装路径直接失败。该版本仍在 Google 仓库索引里（repository2-3.xml），可在 Android Studio SDK Manager 勾 Show Package Details 安装 |
| 测试设备 | 无真机 | `adb devices` 为空；模拟器可用 WHPX（`emulator -accel-check` → WHPX(10.0.19045) installed and usable），AVD `Medium_Phone_API_36.1` 存在 |

`gradlew projects` 与 `gradlew :app:assembleOssDebug` 均已在该环境实际执行：配置阶段成功（打印 `You are running the required go version.` / `You are building rclone v1.71.0`），构建阶段止步于 `:rclone:buildArm` 的 NDK 缺失。

## 2. 测试基建（P0 新增，均在版本控制内）

- `scripts/make-test-corpus.py`：生成计划 §10 的 `/rs-test/` 合成语料，全部是真实编码文件，不靠改扩展名伪装。实测输出 1043 个文件 / 103 MiB，附 `rs-test/manifest.json`（路径 + size + SHA-256，供 D20 内容不变校验）。
  - 已含：baseline/progressive JPEG、大写 `.JPG`、透明 PNG、有损/无损 WebP、BMP、4 帧 GIF、真 HEIC ×3（含 `Orientation=6` 旋转样本，libheif 1.23.4 编码，容器品牌实测 `ftypheic/mif1 heic miaf`）、`.heif` 名样本、真 AVIF（品牌 `ftypavif`，需 Android 14+）、2 秒 H.264 MP4、截断 JPEG、JPEG 内容挂 `.heic` 名、无扩展名、`.bin`、>32MiB 大图、8000×8000（64MP 解码尺寸）、14 个特殊字符文件名（前导 `-`、`+`、`#`、字面 `%2F`、空格、单引号、`&`、`@`、括号、NFC/NFD 两份 `café`、中文、emoji）、整段特殊字符目录名、`subdir-nested/deeper`、空目录、1000 文件批量目录（B07/D02）、`target-conflicts`（同名不同内容 + 同名同内容）、`target-empty`、`target-readonly`。
  - 已知缺口：NTFS 不允许文件名含双引号，计划 C11 的这一类必须在服务器侧造名（后续用测试服务器注入），不能声称已覆盖。
- `tools/webdavtest/`：独立实现的 RFC 4918 服务器（`golang.org/x/net v0.43.0` webdav，锁定与 rclone 同一 x/net 版本、`go 1.24`、`GOTOOLCHAIN=local`）。语料载入内存文件系统，跑写测试不会损坏磁盘原件。提供 JSONL 请求日志（method/path/Destination/Overwrite/Depth/If/status/bytes）、方法计数端点 `GET|POST /__counts`、注入开关：`-move-status`（405/501）、`-force-conflict`（412）、`-move-delay`、`-drop-after-move`（真做 MOVE 后销毁响应）、`-prefix-readonly`（写前缀 403）。
  - 为什么要独立实现而不是用 `rclone serve webdav`：不能让被测客户端自己当服务器，否则 MOVE/Overwrite 语义是自己跟自己约定。

## 3. P0 关键验证：原生 MOVE 的线上行为（对 webdavtest 实测）

用与内置版本相同的 rclone 1.71.0（本机 GOOS=windows 构建，版本串 `1.71.0-roundsync-baseline`）跑，服务器完整记录请求序列：

| 场景 | 实测请求序列 | 结论 |
|---|---|---|
| 目标不存在 | `PROPFIND src ×2` → `PROPFIND dst` = 404 → **`MKCOL target-empty/` = 405** → `MOVE Overwrite: T` = 201 → `PROPFIND dst` | 确实是原生 MOVE，没有 GET/PUT 下载上传（D11 方向成立）；但客户端会主动 `MKCOL` 目标父目录，与计划"不自动建目录"（§8.2 第 6 条、D07）冲突 |
| 目标已存在（同名不同内容） | `PROPFIND src ×2` → `PROPFIND dst` = 207 → **`DELETE dst` = 204** → `MKCOL` = 405 → `MOVE Overwrite: T` = 201 | 覆盖风险不止是 `Overwrite: T`：客户端**先删目标再移动**。事后校验：目标 SHA-256 变成源的 `28d941dd…46f04`，原本 170723 字节 / `8fe5474c…b15dd` 的目标原件已销毁 |
| `--ignore-existing` + `moveto` | 无新请求，进程 exit 0 | 不覆盖，但"跳过"和"已移动"从退出码无法区分，且判断发生在客户端预检 → 计划 §8.1 说的竞态窗口原样存在 |
| 手工 `MOVE` + `Overwrite: F` 打已存在目标 | `412 Precondition Failed` | 该机制在独立服务器上按 RFC 4918 生效，P5 方案方向成立；**群晖是否同样执行仍是未验证项** |
| 手工 `MOVE` + `Overwrite: T` 打已存在目标 | `204`，目标被覆盖 | 说明 rclone 的破坏同时来自客户端预删 + T 头两处，只改一头不够 |

### 3.2 基线 APK 与模拟器实测（2026-09-28）

NDK 装好后 `gradlew :app:assembleOssDebug` 成功（5m26s，64 个任务），4 个 ABI 的 `librclone.so` 各 90–102 MB 确实进了 APK：

| 产物 | SHA-256 |
|---|---|
| `roundsync_v2.5.6-oss-x86_64-debug.apk` | `b6258fe0c5aff94237ff8b0506cc7ca0b0294f2cbb695261b680f4ae7a56f460` |
| `roundsync_v2.5.6-oss-arm64-v8a-debug.apk` | `6bb7190f780b78c6a78dfa2ebf31dfbac8c916f1e831311617965dd2149c5e9b` |
| `roundsync_v2.5.6-oss-universal-debug.apk` | `76cc695670d7d73b22e14aea0d232f9b71333c9be59583f4bac937d328a10f39` |

（armeabi-v7a `32c45aa2…540292`、x86 `c2d44e8f…3913b3`；产物在 `app/build/outputs/apk/oss/debug/`，不入库。）

在 Android 16（API 36.1，x86_64，google_apis_playstore，WHPX）模拟器上实跑基线包，接入本机 webdavtest 语料：

- 连接、列目录、面包屑、特殊字符文件名（前导 `-`、`&`、`@`、空格、中文、emoji、NFC/NFD 两份 `café`、大写 `.JPG`、`.heif`、`.heic`）全部正常显示，大小与 mtime 正确。
- 用 `rclone serve http` 同一版本比对：经 serve 取回的字节与磁盘原件 SHA-256 一致，Content-Type 正确（HEIC 报 `application/octet-stream`）。所以"取文件"这一段没问题。

**新发现的真实缺陷（都有日志或产物证据）**

1. **文件名里的 `#` 和字面 `%2F` 会让缩略图 404**：URL 是字符串直接拼出来的，没有逐段编码。logcat 里两条 `Glide … HttpException 404` 的 URL 分别是 `…/inbox/hash#tag.jpg` 和 `…/inbox/percent%2Fliteral.jpg`。这正是计划 §4.3/C11 担心的那类，P4 必须修。
2. **缩略图默认其实是关的**：`settings_general_preferences.xml` 里写 `defaultValue=true`，但读取方 `FileExplorerFragment` 用的兜底是 `false`；全新安装没进过设置页时偏好里没有这个键 → 实际不显示缩略图。属于"文档/代码不一致"，P1 顺手了断。
3. **视频行会去拉完整视频文件**：`clip_0001.mp4` 走了 Glide 的视频解码（logcat 看到 `c2.android.avc.decoder` 建实例）。计划 §7.4"第一版不为网格封面下载完整视频"这条现在是反的。
4. **服务就绪竞态确认存在**：`pm clear` 后首次进入目录，缩略图请求整体失败且 Glide 缓存目录都没建；来回滚动强制重绑之后请求才成功、缓存才出现。计划 §7.1 的判断成立。

**模拟器不能作为静态图视觉验收环境（重要）**

同一批纯色图（纯白 / 纯红 / 纯蓝 JPEG、PNG）在屏幕上渲染成完全相同的深灰方块 `(26,28,25)`，而 GIF（纯色帧）渲染正确。已排除的原因：Glide 磁盘缓存残留（`pm clear` 后仍复现）、GPU 模式（`gfxstream` 与 `swiftshader_indirect` 相同）、服务端字节（serve 比对一致）、请求失败（该轮无任何 Glide 异常，且缓存里能取到 63×63 的解码结果，纯白图的缓存资源中心像素为 `(255,255,255)`）。也就是说**解码与变换是对的，丢内容发生在"位图进 ImageView 到被截图采到"这一段**（Glide 默认允许硬件位图，动图走的是另一条软件绘制路径）。想关硬件叠加层需要 root，这个 Play 镜像拿不到。

结论：**HEIC 的像素级验收必须上真机**。模拟器上能看到的支持信号只有间接证据——系统 `c2.android.hevc.decoder` 被拉起并输出 640×480（对应 `clip_1003.heif`），且没有 Glide 解码异常；这不足以宣布 HEIC 支持通过。

### 3.4 真实群晖 WebDAV 实测（2026-09-29，DSM 自带 WebDAV）

端点事实：`http://192.168.1.101:5005/`，`Server: Apache`，`WWW-Authenticate: Basic realm="SYNO_WebDAV Storage"` → 这是**群晖 DSM 自带 WebDAV**，不是 AList。remote 的 url 带 `/home/` 前缀，账号 `read`（实测可写）。所有写入都在 `rs-test/` 下自建的 `probe-*` / `px-*` 目录里，测完已 `purge`，根目录恢复原状。

`scripts/probe-move-endpoint.sh` 六个场景（每个场景都带 `-vv --dump headers`，结论按服务端真实收到的动词判定）：

| 场景 | 服务端实际收到的请求序列 | 结果 |
|---|---|---|
| S1 移到已存在空目录 | `PROPFIND×3 → MKCOL → MOVE(Overwrite: T) → PROPFIND` | 移动成功，目标 SHA-256 与源一致（D01/D20 通过） |
| S2 移到同名不同内容目标 | `PROPFIND×3 → `**`DELETE`**` → MKCOL → MOVE(Overwrite: T) → PROPFIND` | **原件被销毁**：目标哈希从 `8fe5474c…b15dd` 变成源的 `7faf530a…acce6`。计划 §8.1 的预删风险在真机群晖上确认存在 |
| S3 `--ignore-existing` | 只有 `PROPFIND×3`，无任何写动词 | 确实跳过（源仍在、目标未变），但**退出码仍是 0**，与真正移动无法区分 |
| S4 目标父目录不存在 | `PROPFIND×3 → MKCOL → MOVE(Overwrite: T) → PROPFIND` | **目录被移动路径建出来了** → 计划"不自动 MKCOL"（§8.2 第 6 条、D07）在真机上也是必须专门防的行为 |
| S5 移动 94 MiB 大文件 | 统计 `serverSideMoves:1 serverSideMoveBytes:98589471 speed:0`，墙钟 1s | 服务端改名，没有手机下载上传回退（D11 通过）；事后字节一致（注意 rclone 的 bytes 是逻辑量，不能当流量证据） |
| S6 源与目标同一路径 | 只有 `PROPFIND×1`，无写动词 | 无操作且文件完好（D08 当前行为安全） |

**最关键的一条：群晖自己执行 `Overwrite: F`。** 用 `tools/wdavproxy`（只转发的日志代理，凭据原样透传、不落盘不打印）直接对已存在目标发原始 `MOVE`：

- `Overwrite: F` → **412 Precondition Failed**，响应体原文 `Destination is not empty and Overwrite is not "T"`；事后核对：源和目标**两个文件都还在、字节都没变**（不是"失败但留下半个"）。
- `Overwrite: T` 对照 → **204**，源消失、目标被覆盖成源内容。

对 P5 的意义：只要补丁后的移动命令做到"不预删目标 + 发 `Overwrite: F` + 不经通用 Move 路径"，覆盖防护就是**服务端保证**，不是客户端预检的竞态窗口；412 可以直接映射成 `CONFLICT`/`SKIPPED`。这条从"未验证"变成"群晖实测通过"。

### 3.5 仍开放的端点项

- AList 那一路（`http://192.168.1.189:5244/dav`）对 WebDAV 写请求仍返回 403（`mkdir`、`PUT` 都是），但 Web UI 建目录正常 → 需在 AList 后台放开该挂载/账号的写权限。app 若继续连 AList，写入同样会被拒。
- 群晖侧未测：405/501 注入、丢响应（`-drop-response`）、断网恢复、崩溃后待核对。代理已具备这些开关。

### 3.1 用户提供的真实端点（2026-09-28 实测）

- 端点：`http://192.168.1.189:5244/`，账号 admin，指定测试目录 `/NAS/test`。
- 根路径只发 HTML，`PROPFIND /` = 405；WebDAV 入口在 **`/dav`** 子路径，remote url 已改为 `http://192.168.1.189:5244/dav`。
- 服务身份：`GET /api/public/settings` 返回 alist-org 标识，前端含 AList/OpenList 字样 → **这是 AList 文件网关，不是群晖 DSM 自带 WebDAV**（`/NAS` 挂载点下能看到 `#recycle`、`.Maildir`、`Drive`、`mysql_backup`，说明确实映射到 DSM 卷根）。
- 用户决定：app 现有连接就是走 AList，所以 **MOVE 验收对象定为 AList**；"群晖原生 WebDAV 语义"因此继续记为未验证，P5 的补丁行为约束不能因为 AList 通过就删掉。
- 凭据：`lsd dev:` 成功；`pass` 以 rclone 混淆形式存在仓库外文件 `D:/Development/RoundSyncTestAssets/rclone-home/nas.conf`，未进仓库、未进日志。密码曾通过聊天传输，已建议轮换。
- **写权限受阻**：`mkdir dev:/NAS/test` = **403 Forbidden**（3 次重试同样）。AList 的挂载点默认只读，需要用户在 AList 后台对该挂载开启"可写"（并确认 admin 角色有写权限、后端目录对 AList 进程可写）。因此 §3 的 S1–S5 真实端点场景尚未执行，命令已备好：`scripts/probe-move-endpoint.sh --conf … --remote dev --base /NAS/test --create-base`。

## 4. 计划核对下来的源码事实（供 P1 起用）

已完整读过 `FileExplorerFragment.java`、`FileExplorerRecyclerViewAdapter.java`、`FileItem.java`、`DirectoryObject.java`、`RemoteItem.java`、`Rclone.java`、`EphemeralTaskManager.kt`、`EphemeralWorker.kt`、`RemoteDestinationDialog.java`、`RemoteFolderPickerFragment.java`、`app/build.gradle`、`rclone/build.gradle`。相对计划的补充/修正：

1. **计划 §1.3 成立**：`searchDirContent()`（`FileExplorerFragment.java:867-893`）确实只在已加载列表内做小写包含匹配、不重列目录，且原始列表保留在 `directoryObject`；缩略图确实走本机 `rclone serve http`（`ThumbnailsLoadingService.java:42`）+ Glide。
2. **缓存键比计划说的更成问题**：`PersistentGlideUrl.getCacheKey()`（`FileExplorerRecyclerViewAdapter.java:225-233`）用 `path.substring(path.indexOf('/', 1))` 去掉随机鉴权段，实际键变成 `/remoteName/相对路径`。随机端口和 auth 被排除（好事），但没有任何 size/mtime/signature → 同路径换文件必然显示旧图。计划"重点补版本/配置变更失效"的判断正确。
3. **`//remoteName` 根标记**：全仓约 40+ 处字面拼接/比较，跨 `Rclone.java`（9 处）、`FileExplorerFragment`（13）、`RemoteFolderPickerFragment`（8）、`ShareFragment`（6）、`RemoteDestinationDialog`（8）、`RemoteConfigHelper`（2）、`RcloneRcd`（1）；真正的形态分叉口只有一个：`FileItem.getPath()`（`FileItem.java:78-82`）在 `startAtRoot` 时给路径补前导 `/`，`Rclone.getDirectoryContent`（`Rclone.java:236-248`）靠 `path != "//"+remoteName` 判断是否附路径。`LegacyPathAdapter` 应以此为唯一收敛点，SFTP 的 `startAtRoot` 语义保持。
4. **选择集合已经是"对象列表"不是下标**：`selectedItems` 是 `List<FileItem>`，靠 `FileItem.equals`（remote + path + name）比对，但 **没有重写 hashCode**，也没有 DiffUtil，任何一次选择变化都 `notifyDataSetChanged()` 全列表重绑。计划的 FileKey 值对象仍然必要（要 hashCode 契约 + 与元数据解耦）。
5. **`onViewRecycled` 不存在**，且 `showThumbnails=false` 时 `holder.fileIcon` 不重置 → 关缩略图偏好后行复用会残留上一张图。
6. **后退比计划更受限**：`pathStack` 是纯 LIFO `Stack<String>`，`onBackButtonPressed`（`:1124-1172`）pop 即销毁；面包屑点击用 `while(pop()!=path)` 砍尾巴（`:1379`）。全仓没有 `OnBackPressedCallback`/Dispatcher，走的是已废弃的 `Activity.onBackPressed` → `MainActivity.java:319`。`buildStackFromPath`（`:474-489`）在 `startAtRoot` 的绝对路径下会退化成只剩根。加"前进"必须换数据结构，符合计划判断。
7. **目录缓存状态语义确实坏**：`DirectoryObject.isContentValid()`（`:71-79`）在路径**不在缓存里时返回 true**；`restoreFromCache()`（`:42-45`）对缺失键直接 `new ArrayList<>(null)` → NPE。失败与"空目录"不可区分。
8. **`RemoteDestinationDialog` 是死代码**：全仓没有任何调用点（只有自身文件内的引用），`onDestinationSelected(String)` 无人接收。计划里"可复用目录展示"的假设要按"没有现成对话框可用"来做；P6 的目标选择器要从零接。
9. **移动链路的退出码问题比计划描述得更具体**：`EphemeralWorker.doWork` 对每一个真正执行过的分支都 `return Result.success()`（`EphemeralWorker.kt:178`），`handleSync` 里 `localProcessReference.waitFor()` 的返回值直接丢弃（`:245`）；`FAILURE_REASON.RCLONE_ERROR`（`:63`）**从来没有被赋值**，所以 `postSync` 恒走"成功通知"分支。同一形状在 `SyncWorker.kt:214` 也有。Rclone 侧 `moveTo(Process)`（`Rclone.java:872-897`）也不看退出码。
10. **`cancelAllWork` 是全局的**：`EphemeralTaskManager.kt:113-116`、`SyncManager.kt:53-56`、`updates/workmanager/UpdateManager.kt:37`。计划的"只按批次 tag 取消"必须避开这三个入口；当前所有 ephemeral 任务 tag 全被硬编码成 `""`（`:35/:53/:72/:89`），等于无标签。
11. **传参是 `String[]` argv，无 shell**（`Rclone.java:86-109` + `Runtime.exec(String[])`），空格/`#`/`%` 天然安全；但仓库里**没有任何一处用 `--` 终止选项解析**，前导 `-` 文件名会被 rclone 当开关 → 计划 §8.2 的 `--` 约定必须新加。另外 `Rclone.java:425` 每次调用都会先 exec 一次裸 `librclone.so` 探测进程，浪费且有副作用。
12. **配置指纹可行**：`Rclone.getConfig(name)`（`:524-562`）返回单个 remote 的全部选项 map（含 `pass` 等机密，取指纹时必须按 key 白名单过滤）；`RemoteItem` 只有 name/typeReadable/isCrypt/isAlias/isPathAlias/isCache，没有 UUID，端点/root 只在配置里。计划的 `profileFingerprint` 只能取 `type` + `url` + `root` 之类的非密码字段。
13. **缩进一处服务就绪竞态**：`startThumbnailService()`（`:733-744`）fire-and-forget，没有任何就绪等待；端口靠"开一个 ServerSocket 再关掉"抢占（`:754-764`，TOCTOU），`RcloneRcd.isOnline` 存在但没被用于此。计划 §7.1 的"等服务可用再发请求"确实没做。

## 5. 阶段状态

| 阶段 | 状态 |
|---|---|
| P0 | 只剩一项外部阻塞。已完成：环境与基线核对、rclone 1.71.0 确认、基线 ossDebug APK（4 ABI 原生库 + SHA-256）、测试语料、独立 WebDAV 测试服务器、日志转发代理、rclone 移动行为线上实测、**真实群晖 WebDAV 六场景 + `Overwrite: F`→412 实测**、基线 app 在模拟器上实跑并定位 4 个真实缺陷。**遗留阻塞**：真机 HEIC/AVIF 像素级验收（模拟器截图链路采不到 Glide 静态图位图，见 §3.2）。AList 那一路写权限仍是 403，但验收主端点已换成 DSM 自带 WebDAV |
| P1–P7 | 未开始 |

## 6. 明确未验证 / 未测项

- HEIC/HEIF 在**任何真实手机**上的解码与方向正确性：未测。模拟器只能给出"系统 HEVC 解码器被拉起、无 Glide 异常"的间接信号，且静态图渲染采集不到，不能当作通过。
- AVIF：未测（真 AVIF 语料已备好）。
- AList 代理层的移动语义：未测（写请求 403）。DSM 自带 WebDAV 的结论不能自动搬过去。
- 群晖侧未测：405/501 注入、丢响应、断网恢复、崩溃后待核对（代理与测试服务器的开关都已具备）。
- §4 的源码结论是静态读码，不是运行时验证。
- 双引号文件名（C11 一类）：NTFS 造不出来，需服务器侧造名，目前缺口。
