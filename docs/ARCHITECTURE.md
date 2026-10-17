# 架构设计

> 项目：百度网盘不限大小不限速解析（`baidujiexi`）
> 版本基线：`1.2.8+11`
> 适用平台：Android（arm64-v8a）、Windows（x64）

本文描述系统的分层结构、模块职责、关键链路时序、状态机与容错设计。接口字段与签名算法细节见 [API.md](API.md)，构建与发版见 [BUILD.md](BUILD.md)。

---

## 目录

- [1. 设计目标与约束](#1-设计目标与约束)
- [2. 分层结构](#2-分层结构)
- [3. 模块职责](#3-模块职责)
- [4. 依赖方向与边界规则](#4-依赖方向与边界规则)
- [5. 关键链路时序](#5-关键链路时序)
- [6. 下载状态机](#6-下载状态机)
- [7. 容错与自愈设计](#7-容错与自愈设计)
- [8. 平台差异抽象](#8-平台差异抽象)
- [9. 线程与并发模型](#9-线程与并发模型)
- [10. 数据持久化](#10-数据持久化)
- [11. 可观测性与调试](#11-可观测性与调试)
- [12. 演进方向](#12-演进方向)

---

## 1. 设计目标与约束

| 目标 | 说明 | 实现手段 |
| --- | --- | --- |
| 单一代码库双端运行 | Android 与 Windows 共用同一套 Dart 业务层 | Flutter + MethodChannel 抽象平台能力 |
| 解析逻辑与 UI 解耦 | UI 不直接拼装 HTTP 请求 | `ParseApiClient` 统一出口 |
| 平台能力可替换 | 下载引擎在两端实现不同 | `GopeedEngine` 对外暴露统一 REST 语义 |
| 弱网可用 | 应对 429 限流、连接中断 | 有限重试 + 引擎自愈 |
| 配置可远程下发 | 换域名、改公告无需发版 | `RemoteConfigService` |

**硬性约束**

1. 解析站接口存在请求签名校验，缺失或错误的 `rand1/rand2/rand3` 会被拒绝，因此所有请求必须经由 `ParseApiClient._send`。
2. 下载引擎只暴露 HTTP REST（Android 由 AAR 在进程内启动，Windows 为独立子进程），业务层不得依赖引擎内部结构。
3. Android 仅打包 `arm64-v8a`，因此所有原生依赖（`libgopeed.aar`、`libc++_shared.so`）必须是 arm64 版本。
4. 密码查询页依赖真实 WebView 内核，桌面端没有等价能力，必须做能力降级。

---

## 2. 分层结构

```
┌──────────────────────────────────────────────────────────────┐
│                        表现层 (lib/ui)                        │
│  main.dart  home_page.dart  downloads_page.dart               │
│  pwd_query_page.dart  app_popup_dialog.dart                   │
│  theme/app_theme.dart                                         │
└───────────────┬──────────────────────────────────────────────┘
                │ 调用（单向）
┌───────────────▼──────────────────────────────────────────────┐
│                      领域/服务层 (lib/core)                    │
│  ParseApiClient    DownloadManager    RemoteConfigService     │
│  StorageService    GopeedEngine       RequestSigner           │
│  models.dart（值对象与解析）                                    │
└───────┬──────────────────────────────┬───────────────────────┘
        │ HTTP (dart:io / http)        │ MethodChannel / REST
┌───────▼──────────────┐   ┌───────────▼───────────────────────┐
│   远程解析站 / 配置站   │   │        原生层 / 外部进程            │
│  mf.dg22.top          │   │  Android: MainActivity + Bridges   │
│  ai.yodlx.com         │   │  Windows: gopeed-rest.exe          │
└──────────────────────┘   └───────────────────────────────────┘
```

### 2.1 表现层

| 文件 | 职责 |
| --- | --- |
| `main.dart` | 应用入口、主题装配、启动引导（远程配置 → 覆盖 baseUrl → 加载 token → 拉取解析配置）、错误重试页 |
| `ui/home_page.dart` | 主工作台：链接输入、文件列表、勾选、解析、直链结果、验证码弹窗、公告与运营弹窗 |
| `ui/downloads_page.dart` | 下载任务列表、进度/速度展示、暂停/继续/删除、打开目录与文件 |
| `ui/pwd_query_page.dart` | 内嵌 WebView 的密码查询页，注入 JS 桥自动完成 Turnstile → 输入密码 → 读取结果 |
| `ui/app_popup_dialog.dart` | 通用运营弹窗渲染，支持无动作/外链/QQ 跳转 |
| `theme/app_theme.dart` | Material 3 配色、亮暗主题切换、`AppColors.setBrightness` |

表现层不做协议拼装、不做签名、不直接读写平台目录。

### 2.2 领域/服务层

| 文件 | 职责 | 是否为单例 |
| --- | --- | --- |
| `core/api_client.dart` | 解析站全部接口调用、签名注入、429 重试、错误归一 | 否（`_Bootstrap` 持有实例） |
| `core/signature.dart` | `sha1Hex` 与设备指纹生成，产出 `rand1/rand2/rand3` | 静态工具 |
| `core/models.dart` | `ParseConfig`、`FileItem`、`FileListData`、`DirectLink`、`VcodeInfo`、`ShareLink`、`AppPopup`、`ParseException` | 纯数据 |
| `core/remote_config.dart` | 远程配置拉取与进程内缓存 | 进程级静态缓存 |
| `core/gopeed_engine.dart` | 引擎生命周期与 REST 封装（创建/查询/暂停/继续/删除任务） | 由 `DownloadManager` 持有 |
| `core/download_manager.dart` | 任务集合、进度轮询、状态映射、引擎自愈 | **是**（单例 `ChangeNotifier`） |
| `core/storage_service.dart` | 下载目录解析、可写性校验、自定义目录持久化 | 静态方法集合 |

---

## 3. 模块职责

### 3.1 `ParseApiClient`

- 持有 `baseUrl`（默认 `https://mf.dg22.top/api/v1`，可被远程配置覆盖）。
- `loadToken()` / `setToken()` 读写 `SharedPreferences` 的 `parse_token`，缺省 `guest`。
- 对外方法：`getConfig()`、`getLimit()`、`getFileList()`、`getVcode()`、`getDownloadLinks()`。
- `_send` 是唯一网络出口，负责：
  1. 调用 `RequestSigner.sign` 注入签名；
  2. GET 走 query、POST 走 JSON body；
  3. 捕获 429 并按 `Retry-After` 退避重试（最多 2 次）；
  4. 处理 SourceGuardian 混淆输出；
  5. 业务码非 200 时抛 `ParseException`。

### 3.2 `RequestSigner`

- `rand1 = SHA1(jsonEncode(业务字段))`；
- `rand2` = 32 位十六进制设备指纹，持久化键 `client_fingerprint_v1`；
- `rand3 = SHA1(rand2)`；
- 三个字段按 `业务字段 → rand1 → rand2 → rand3` 顺序写入，顺序影响序列化结果，进而影响 `rand1` 的判定。

> 详细推导与陷阱见 [API.md#2-请求签名](API.md)。

### 3.3 `RemoteConfigService`

- 地址常量 `https://ai.yodlx.com/api/app2/config.php`，超时 8s。
- 进程内静态缓存 `_cached`，避免每次启动重复请求；`load({useCache: false})` 可强制刷新。
- 兼容响应体为 `{code, data}` 包裹或裸对象两种形态。
- 解析字段：`parseApiBase`、`announcement`、`parsePassword`、`pwdSiteUrl`、`pwdFirstPassword`、`popup`、`pwdPopup`。

### 3.4 `GopeedEngine`

统一两端差异：

| 能力 | Android | Windows |
| --- | --- | --- |
| 启动 | MethodChannel `com.liuguang.bdmfjx/gopeed` → `Mobile.start(configJson)`（后台线程） | 以子进程启动 `gopeed-rest.exe`，从 stdout 解析 `GOPEED_PORT=` |
| 地址 | 配置 `127.0.0.1:0`，由 AAR 自行监听 | 解析端口后拼接 `http://127.0.0.1:<port>` |
| 停止 | `Mobile.stop()` | `taskkill /IM gopeed-rest.exe /F` |
| 存储 | `storageDir = filesDir/gopeed` | 引擎默认工作目录 |

对外统一提供：`start()`、`createTask()`、`task()`、`tasks()`、`pauseTask()`、`continueTask()`、`deleteTask()`。
异常统一为 `GopeedApiException{statusCode, message, isConnectionError}`。

### 3.5 `DownloadManager`

- 单例 `ChangeNotifier`，UI 通过 `AnimatedBuilder`/`ListenableBuilder` 订阅。
- 持有任务列表 `List<DownloadItem>`，轮询周期 800ms。
- 负责引擎懒启动（`_ensureEngine()`）、任务状态映射、连接类错误自愈、`restore()` 恢复历史任务。
- `fileNameFromUrl` 优先取 URL 中的 `outname=` 参数，其次取 path 末段。

### 3.6 `StorageService`

- 目录优先级：自定义目录 → 平台默认目录 → 回退目录。
- `_isWritable`：Android 通过 `ensureDir` 原生校验；其它平台写探针文件 `.tierflow_write_probe`。
- 自定义目录写入 `SharedPreferences` 的 `download_dir_custom`，并校验 `setString` 返回值。

---

## 4. 依赖方向与边界规则

```
ui ──► core ──► (网络 / 平台通道)
ui ──► models（只读值对象）
core ──► models
```

**边界规则**

1. `core` 不得 `import 'ui/...'`，保证服务层可在无 UI 环境下被测试。
2. `ui` 不直接 `import 'package:http/http.dart'`，所有请求经 `ParseApiClient`。
3. `models.dart` 不依赖任何服务，只做纯函数解析（如 `parseShareLink`、`DirectLink.parseList`）。
4. 原生通道名集中定义在各自 service 的私有常量中，避免散落字符串。

---

## 5. 关键链路时序

### 5.1 启动引导

```
main()
  └─ runApp(TierFlowApp)
       └─ _Bootstrap
            ├─ RemoteConfigService().load()          // 8s 超时，失败不阻塞
            ├─ base = remote.parseApiBase            // 非空则覆盖
            ├─ client.baseUrl = base
            ├─ client.loadToken()                    // prefs: parse_token
            ├─ client.getConfig()                    // 解析配置
            └─ HomePage(config, announce, ...)
```

失败时展示错误页与「重试」，重试调用 `_reload()`，其中 `load(useCache: false)` 强制刷新远程配置。

### 5.2 解析文件列表

```
用户粘贴链接
  └─ parseShareLink(text) ──► ShareLink{pwd, url} 或 null
       └─ _loadFileList()
            ├─ 需要密码且本地无 _parsePassword → _ensureParsePassword()
            │     ├─ 远程配置有 parsePassword → 直接使用
            │     └─ 否则弹窗要求输入 / 打开密码查询页
            ├─ client.getFileList(shareUrl, pwd, dir)
            │     ├─ 成功 → FileListData{title, files, ...}
            │     └─ ParseException.needCaptcha → _fetchVcode() → 弹窗输入 → 重试
            └─ 渲染文件列表（目录可下钻，支持全选/反选）
```

目录浏览通过 `dir` 参数实现，每次下钻都是一次新的 `getFileList` 调用。

### 5.3 批量解析直链

```
_startList() / _parseSelected()
  ├─ 过滤：跳过目录项、跳过无效条目
  ├─ 串行遍历选中文件
  │    └─ client.getDownloadLinks(file)
  │         ├─ 成功 → DirectLink.parseList → 追加 _results
  │         └─ needCaptcha → _fetchVcode() → 单次交互后继续
  └─ 结果区展示直链，可复制 / 浏览器打开 / 交给引擎下载
```

采用串行而非并发，目的是避免触发站点频控，同时让验证码交互有确定顺序。

### 5.4 引擎下载

```
用户点击「下载」
  └─ DownloadManager.download(url, name)
       ├─ _ensureEngine()
       │    ├─ 已存活 → 复用
       │    └─ 否则 engine.start()
       ├─ fileNameFromUrl(url)（优先 outname=）
       ├─ engine.createTask({url, name, dir, headers})
       ├─ 插入 DownloadItem(status: running)
       └─ _startPolling()  // 800ms
            └─ engine.tasks()
                 ├─ 正常 → 更新进度/速度/状态
                 └─ GopeedApiException.isConnectionError
                      └─ 引擎自愈：重启一次 → 重新建任务
```

---

## 6. 下载状态机

`DownloadStatus` 枚举与引擎状态映射：

```
                    ┌──────────┐
     创建任务 ──────►│  ready   │
                    └────┬─────┘
                         │ 引擎开始执行
                    ┌────▼─────┐
              ┌─────│ running  │─────┐
              │     └────┬─────┘     │
   用户暂停    │          │ 完成       │ 引擎排队
        ┌─────▼────┐ ┌───▼────┐  ┌───▼─────┐
        │ paused   │ │  done  │  │ waiting │
        └─────┬────┘ └────────┘  └────┬────┘
              │ 继续                   │ 轮到执行
              └──────► running ◄───────┘

   任意非终态 ──错误──► error ──重试──► running
```

| 枚举 | 中文标签 | 终态 | 活跃 |
| --- | --- | --- | --- |
| `ready` | 准备中 | 否 | 否 |
| `running` | 下载中 | 否 | 是 |
| `waiting` | 排队中 | 否 | 是 |
| `paused` | 已暂停 | 否 | 否 |
| `error` | 出错 | 是 | 否 |
| `done` | 已完成 | 是 | 否 |

`fromEngine` 负责把引擎返回的字符串状态归一为上述枚举；未知状态降级为 `waiting`，避免 UI 出现空洞。`isTerminal` 用于决定是否停止轮询该任务，`isActive` 用于计算全局速度与「全部暂停」按钮可用性。

---

## 7. 容错与自愈设计

### 7.1 HTTP 层

| 场景 | 策略 |
| --- | --- |
| 429 限流 | 读取 `Retry-After`，`clamp(1, 10)` 秒；缺省 3s；最多重试 2 次 |
| SourceGuardian 混淆 | 特判响应体，转换为可读错误而非 JSON 解析崩溃 |
| 业务码非 200 | 抛 `ParseException(message)` |
| 需要图形验证码 | `message.contains('-20')` → `needCaptcha == true` |
| 超时 | 统一 30s |

### 7.2 引擎层

`GopeedApiException.isConnectionError` 是自愈决策的唯一开关：

```
连接类错误?
 ├─ 是 → 引擎可能已退出
 │       ├─ 重启引擎（仅一次）
 │       ├─ 重建任务
 │       └─ 仍失败 → 标记 error，提示用户
 └─ 否 → 业务错误（如磁盘满、URL 失效）
          └─ 直接标记 error，不重启
```

Windows 侧额外限制：`_waitEnginePort` 最长等待 20s，最多尝试 2 次；启动前先 `taskkill /IM gopeed-rest.exe /F` 清理僵尸进程，避免端口/文件锁冲突。

### 7.3 密码查询页

| 限制 | 常量 | 行为 |
| --- | --- | --- |
| Hybrid Composition 阈值 | `kHybridCompositionBelowMajor = 86` | 内核低于 86 时关闭混合合成，规避渲染问题 |
| 最低内核 | `kMinWebViewMajor = 70` | 低于则拒绝进入并引导升级 |
| Turnstile 提交上限 | `TS_MAX = 2` | 超过即放弃，避免死循环 |
| 密码提交上限 | `PWD_MAX = 2` | 同上 |
| 自动提交节流 | 距加载 1.5s + 6s | 防止页面未就绪时误触 |

无 WebView 能力（桌面端）时直接降级：提示用户手动输入密码，不阻塞主流程。

---

## 8. 平台差异抽象

三个 MethodChannel 构成平台能力边界：

| 通道 | 方法 | Android 实现 | Windows 实现 |
| --- | --- | --- | --- |
| `com.liuguang.bdmfjx/gopeed` | `start` / `stop` | `GopeedBridge` → `Mobile.start/stop` | 子进程管理（Dart 侧直接实现） |
| `com.liuguang.bdmfjx/storage` | `getDefaultDir` / `getFallbackDir` / `hasPermission` / `requestPermission` / `ensureDir` | `StorageBridge` | Dart 侧回退实现 |
| `com.liuguang.bdmfjx/webview` | `getWebViewMajor` | `WebViewBridge` 正则取 `Chrome/(\d+)\.` | 返回 null（不支持） |

**约定**：调用方必须对 `MissingPluginException` / `PlatformException` 做兜底，任何平台能力缺失都不得导致应用崩溃。

### 8.1 Android 存储权限分代

| API | 策略 |
| --- | --- |
| 24–28 | 运行时申请 `WRITE_EXTERNAL_STORAGE` |
| 29 | `requestLegacyExternalStorage="true"` |
| 30+ | 跳转 `ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION`，用 `Environment.isExternalStorageManager()` 判定 |

`StorageBridge.REQUEST_CODE = 0x5744`，权限结果由 `MainActivity.onRequestPermissionsResult` 转发回 Dart。

### 8.2 WebView 内核探测

`WebViewBridge` 从 `WebSettings.getDefaultUserAgent` 中用 `CHROME_UA = Regex("Chrome/(\\d+)\\.")` 提取主版本；异常时返回 `null`，由 Dart 侧按「未知版本」处理。

---

## 9. 线程与并发模型

- **Dart 侧**：单 isolate。网络请求与轮询均为异步，不阻塞 UI。
- **Android 引擎启动**：`GopeedBridge.start` 在后台 `Thread` 中调用 `Mobile.start`，捕获 `Throwable` 后以错误码回传；避免主线程被 AAR 初始化阻塞。
- **Windows 引擎启动**：`Process.start` 后异步读取 stdout，匹配 `GOPEED_PORT=` 或 `GOPEED_ERROR=`，超时 20s。
- **轮询**：`Timer.periodic(800ms)`，单次 tick 内合并为一次 `tasks()` 请求，避免 N 个任务 N 次请求。
- **UI 更新**：`ChangeNotifier.notifyListeners()` 驱动，禁止在 `build` 中触发网络。

**并发上限**：引擎 `downloadConfig.maxRunning = 3`，超出部分由引擎排队（映射为 `waiting`）。
**线程数**：`ParseConfig.downloadThreads` 默认 16，`clamp(1, 512)`。

---

## 10. 数据持久化

| 存储 | 键 | 内容 |
| --- | --- | --- |
| `SharedPreferences` | `parse_token` | 解析站 token，缺省 `guest` |
| `SharedPreferences` | `client_fingerprint_v1` | 32 位十六进制设备指纹（`rand2`） |
| `SharedPreferences` | `download_dir_custom` | 用户自定义下载目录 |
| 引擎 bolt 存储 | — | 任务元数据（Android 位于 `filesDir/gopeed`） |

**缓存策略**

- 远程配置：进程内 `_cached`，生命周期与进程一致，不落盘。
- 文件列表 / 直链：不缓存，每次实时请求，避免直链过期导致下载失败。

---

## 11. 可观测性与调试

项目未接入第三方日志/监控，调试依赖：

1. `flutter run` 的控制台输出（`debugPrint`）。
2. Windows 引擎子进程的 stdout/stderr，可重定向到 `smoke_out.log` / `smoke_err.log`。
3. Android 侧 `adb logcat` 过滤 `com.liuguang.bdmfjx`。
4. 临时截图/UI dump 文件统一以 `.tmp_*` 前缀命名，已被 `.gitignore` 排除。

**建议排查顺序**：远程配置是否可达 → `baseUrl` 是否被覆盖 → 签名是否生效（看是否返回签名错误）→ 是否触发 429/验证码 → 引擎端口是否就绪。

---

## 12. 演进方向

当前架构刻意保持简单，以下为可扩展点（非承诺实现）：

1. **状态管理**：现为 `ChangeNotifier` + 局部 `setState`，任务量增大后可引入统一状态容器。
2. **任务持久化**：目前依赖引擎自身存储，应用重启后通过 `restore()` 拉取，可考虑本地落盘做离线展示。
3. **并发解析**：`_parseSelected` 串行，可在保证频控的前提下改为带信号量的有限并发。
4. **多架构支持**：现仅 arm64-v8a，若需 armeabi-v7a 必须补充对应 AAR 与 `.so`。
5. **桌面端密码查询**：可用 WebView2 补齐与 Android 对齐的能力。
