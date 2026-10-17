# 百度网盘不限大小不限速解析（baidujiexi）

> Flutter 跨平台客户端：粘贴百度网盘分享链接 → 解析文件列表 → 取直链 → 内嵌 Gopeed 引擎多线程下载。
> 支持 Android（arm64-v8a）与 Windows x64，同一套 Dart 业务代码。

<p align="left">
  <img alt="Flutter" src="https://img.shields.io/badge/Flutter-3.44.7-02569B?logo=flutter&logoColor=white">
  <img alt="Dart" src="https://img.shields.io/badge/Dart-3.12.2-0175C2?logo=dart&logoColor=white">
  <img alt="Platform" src="https://img.shields.io/badge/Android-arm64--v8a-3DDC84?logo=android&logoColor=white">
  <img alt="Platform" src="https://img.shields.io/badge/Windows-x64-0078D4?logo=windows&logoColor=white">
  <img alt="Version" src="https://img.shields.io/badge/version-1.2.8%2B11-blue">
</p>

---

## ⚠️ 免责声明

本项目仅供**个人学习与技术研究**使用，用于研究 HTTP 接口签名、Flutter 与原生桥接、Go 引擎内嵌等工程实践。

- 本项目**不提供、不托管、不分发**任何网盘账号、会员权益或侵权内容；
- 解析服务由第三方站点提供，本客户端只是其接口的调用方，**不对服务可用性、合法性作任何保证**；
- 请勿将本项目用于商业用途、批量抓取、二次分发或任何违反《百度网盘服务协议》及相关法律法规的行为；
- 因使用本项目产生的一切后果由使用者自行承担。

如相关权利方认为本项目存在问题，请提交 Issue，仓库维护者会及时处理。

---

## 目录

- [功能特性](#功能特性)
- [运行截图与界面结构](#运行截图与界面结构)
- [技术栈](#技术栈)
- [项目结构](#项目结构)
- [快速开始](#快速开始)
- [核心流程](#核心流程)
- [架构设计](#架构设计)
- [接口与签名](#接口与签名)
- [远程配置](#远程配置)
- [Gopeed 下载引擎](#gopeed-下载引擎)
- [WebView 密码查询](#webview-密码查询)
- [存储与权限](#存储与权限)
- [构建与发布](#构建与发布)
- [测试](#测试)
- [版本历史](#版本历史)
- [常见问题](#常见问题)
- [深入文档](#深入文档)

---

## 功能特性

| 模块 | 能力 |
| --- | --- |
| 链接识别 | 支持 `https://pan.baidu.com/s/xxxx` 与 `pan.baidu.com/wap/init/?surl=xxxx`；自动从纯文本中提取链接与 `提取码：vD32` / `?pwd=vD32` |
| 目录浏览 | 解析分享根目录与多级子目录，支持返回上级；文件类型/大小/修改信息展示 |
| 批量解析 | 勾选多个文件后**串行**请求直链，避免触发站点限流；按站点规则过滤体积/数量 |
| 图形验证码 | 服务端返回 `-20` 时自动拉取 `get_vcode`，弹窗输入后重试 |
| 下载引擎 | 内嵌 Gopeed（Go）引擎，多连接多线程下载，支持暂停 / 继续 / 删除 / 删除文件 |
| 断点续传 | 引擎任务元数据落盘（bolt），App 重启后通过 `GET /tasks` 恢复任务列表 |
| 引擎自愈 | 连接类错误自动 `forceReset()` + 重启引擎并重试一次，避免死端口导致永久失败 |
| 下载目录 | 自定义目录 / 系统公共 Download / 应用专属目录三级回退，写入探针校验可写 |
| 远程配置 | 接口域名、公告、解析密码、弹窗、密码查询站地址全部云端下发，改配置无需重新发版 |
| 密码查询 | 内置 WebView 走 Cloudflare Turnstile 人机验证，自动完成三步流程并回填解析密码 |
| 主题 | Material 3 明/暗双主题，跟随系统或手动切换 |
| 下载直链 | 解析结果支持复制直链、复制文件名、浏览器打开、一键引擎下载 |

---

## 运行截图与界面结构

```
┌──────────────────────────────────────────┐
│  百度公益解析        🔑  🌓  ⬇  ⟳        │  ← AppBar：密码查询 / 主题 / 任务 / 刷新
├──────────────────────────────────────────┤
│  公告卡片（远程下发，可隐藏）             │
│  ┌────────────────────────────────────┐  │
│  │ 分享链接  [ 粘贴 / 粘贴板 ]          │  │
│  │ 提取码    [ 4 位 ]                  │  │
│  │ token     [ 可隐藏 ]                │  │
│  │        [ 开始解析 ]                 │  │
│  └────────────────────────────────────┘  │
│  配额：剩余 N 次 / X GB                  │
├──────────────────────────────────────────┤
│  当前目录：/                               │
│  ☑ 文件名               大小      操作    │
│  ☐ 电影.mkv             2.1 GB   [解析]  │
│  📁 子目录                              │
├──────────────────────────────────────────┤
│  解析结果（直链列表）                     │
│  [复制] [浏览器打开] [引擎下载]           │
└──────────────────────────────────────────┘
```

主要页面：

| 文件 | 职责 |
| --- | --- |
| `lib/ui/home_page.dart` | 首页：链接输入、目录浏览、勾选、批量解析、结果展示 |
| `lib/ui/downloads_page.dart` | 下载任务列表：进度、速度、暂停/继续/删除、下载目录设置 |
| `lib/ui/pwd_query_page.dart` | 内置 WebView 密码查询（Turnstile + 双层密码） |
| `lib/ui/app_popup_dialog.dart` | 后台下发的启动弹窗（链接 / QQ 群） |

---

## 技术栈

| 层 | 选型 | 说明 |
| --- | --- | --- |
| UI | Flutter 3.44.7 / Dart 3.12.2 | Material 3，单代码库支持 Android + Windows |
| 状态 | `StatefulWidget` + `ChangeNotifier` | 无第三方状态管理，降低依赖面 |
| 网络 | `package:http` 1.2.2 | 超时、429 退避、错误映射统一收口 |
| 存储 | `shared_preferences` | token、设备指纹、自定义下载目录 |
| 签名 | `package:crypto` | SHA-1 十六进制摘要 |
| 密码查询 | `webview_flutter` 4.14.1 + `webview_flutter_android` 4.12.0 | 需 Android 侧 `displayWithHybridComposition` 降级 |
| 下载引擎 | Gopeed（Go） | Android 走 AAR + `Mobile.start()`；Windows 走 `gopeed-rest.exe` 子进程 |
| 原生桥 | Kotlin MethodChannel | 引擎启停 / 存储权限 / WebView 内核探测 |

---

## 项目结构

```
TierFlow/
├── lib/
│   ├── main.dart                     # 应用外壳：主题、启动引导（先拉远程配置再进首页）
│   ├── core/
│   │   ├── api_client.dart           # 解析站 API 客户端（签名、429 退避、错误映射）
│   │   ├── signature.dart            # rand1 / rand2 / rand3 请求签名
│   │   ├── models.dart               # 配置、配额、文件、直链、分享链接、异常模型
│   │   ├── remote_config.dart        # 自有后端远程配置（8s 超时 + 进程内缓存）
│   │   ├── gopeed_engine.dart        # Gopeed 引擎桥接（MethodChannel / 子进程 + REST）
│   │   ├── download_manager.dart     # 任务管理、800ms 轮询、引擎自愈
│   │   └── storage_service.dart      # 下载目录解析、可写性校验、权限申请
│   ├── theme/
│   │   └── app_theme.dart            # Material 3 明/暗调色板
│   └── ui/
│       ├── home_page.dart            # 首页
│       ├── downloads_page.dart       # 下载任务页
│       ├── pwd_query_page.dart       # WebView 密码查询页
│       └── app_popup_dialog.dart     # 启动弹窗
├── android/
│   ├── app/
│   │   ├── libs/libgopeed.aar        # Gopeed Go 引擎（arm64-v8a，约 64.8 MB）
│   │   ├── src/main/
│   │   │   ├── kotlin/com/liuguang/bdmfjx/
│   │   │   │   ├── MainActivity.kt   # 注册三个 MethodChannel
│   │   │   │   ├── GopeedBridge.kt   # 引擎启停（后台线程 + Throwable 兜底）
│   │   │   │   ├── StorageBridge.kt  # 目录解析 / 权限 / ensureDir
│   │   │   │   └── WebViewBridge.kt  # 探测 WebView 内核主版本
│   │   │   ├── jniLibs/arm64-v8a/libc++_shared.so
│   │   │   └── AndroidManifest.xml
│   │   └── build.gradle.kts          # abiFilters=arm64-v8a、legacyPackaging=true
│   └── .gitignore
├── windows/
│   └── runner/
│       ├── gopeed-rest.exe           # Gopeed 引擎子进程（约 43.0 MB）
│       ├── CMakeLists.txt            # POST_BUILD 自动复制引擎到可执行目录
│       └── ...                       # Flutter Windows runner 模板
├── test/widget_test.dart             # 分享链接解析 + SHA-1 标准向量
├── docs/                             # 架构 / API / 构建 深度文档
├── pubspec.yaml
└── README.md
```

---

## 快速开始

### 环境要求

| 项 | 版本 |
| --- | --- |
| Flutter | 3.44.7 stable（Dart 3.12.2+） |
| Android | JDK 17、Android SDK（compileSdk 跟随 Flutter）、NDK（跟随 Flutter） |
| Windows | Visual Studio 2022（含「使用 C++ 的桌面开发」）、CMake 3.14+ |

### 运行

```bash
flutter pub get

# Android（仅 arm64 设备/模拟器）
flutter run -d <android-device-id>

# Windows
flutter run -d windows
```

### 构建

```bash
# Android 发布包（仅 arm64-v8a）
flutter build apk --release --target-platform android-arm64

# Windows 发布包
flutter build windows --release
```

产物位置：

- `build/app/outputs/flutter-apk/app-release.apk`
- `build/windows/x64/runner/Release/`（`tierflow.exe` + `gopeed-rest.exe` + `data/`）

> ⚠️ `android/.gitignore` 默认忽略 `gradlew` / `gradle-wrapper.jar` / `local.properties`。
> 克隆仓库后若 Gradle 构建失败，执行 `flutter create .` 重新生成，或手动补回 wrapper 并创建
> `android/local.properties`（内容为 `flutter.sdk=<Flutter SDK 绝对路径>`）。

---

## 核心流程

### 1. 启动引导

```
main()
  └─ TierFlowApp（ThemeMode.system + AppColors 亮度同步）
       └─ _Bootstrap._boot()
            ├─ RemoteConfigService().load()        # 拉取 ai.yodlx.com 配置（8s 超时）
            ├─ baseUrl = remote.parseApiBase       # 云端域名覆盖内置 mf.dg22.top
            ├─ client.loadToken()                  # SharedPreferences: parse_token（默认 guest）
            └─ client.getConfig()                  # GET /user/parse/config
                 └─ 成功 → HomePage；失败 → 「配置加载失败 / 重试」
```

`HomePage.initState()` 会再拉一次远程配置（命中进程内 `_cached`），把公告、解析密码、
密码查询站地址、启动弹窗写入本地状态，并在需要时弹出启动弹窗（每次启动仅一次）。

### 2. 解析文件列表

```
用户粘贴链接
  └─ parseShareLink(raw)
       ├─ /s/([A-Za-z0-9_-]+)          → surl
       ├─ ?pwd=xxxx 或 「提取码：xxxx」  → pwd（4 位）
       └─ 规范化 url = https://pan.baidu.com/s/<surl>[?pwd=<pwd>]

_startList()
  ├─ _ensureParsePassword()   # 为空则 useCache:false 重拉远程配置
  └─ POST /user/parse/get_file_list
        {url, surl, pwd, dir, parse_password, token, rand1, rand2, rand3}
        → {list[], randsk, uk, shareid}
```

点击目录 → 以 `dir = item.path` 递归调用同一接口；`category == -1` 的条目不可勾选。

### 3. 解析直链

```
_parseSelected()
  ├─ 过滤：文件夹 / 小于 min_single_filesize / 大于 max_single_filesize
  ├─ 校验：总和 > max_all_filesize → 报错；数量 > max_once → 报错
  └─ for 每个文件（串行）:
        POST /user/parse/get_download_links
             {randsk, uk, shareid, fs_id[], dlink[], surl, dir, pwd,
              token, parse_password, vcode_str, vcode_input}
        ├─ 成功 → DirectLink.parseList(data)  # 展开 urls[]，继承 filename / ua
        └─ ParseException.needCaptcha（message 含 "-20"）
              └─ POST /user/parse/get_vcode → 弹窗输入 → 用户重试
```

### 4. 引擎下载

```
_downloadWithEngine(url, name, ua)
  └─ DownloadManager.download(headers: {'User-Agent': ua})
       ├─ _ensureEngine()  → 解析目录 + GopeedEngine.start(dir, maxRunning:3)
       ├─ POST http://127.0.0.1:<port>/api/v1/tasks
       │    req = {url, extra:{method:'GET', header:{User-Agent}}}
       │    opts = {name, path, extra:{connections:3}}
       ├─ 连接错误 → forceReset() → 重启引擎 → 重试一次
       └─ 800ms Timer.periodic → GET /tasks/<id> → 刷新 items → notifyListeners()
```

---

## 架构设计

```
┌─────────────────────────────────────────────────────────────┐
│                      Flutter (Dart)                          │
│                                                              │
│  ui/home_page ──┬── core/api_client ── core/signature        │
│  ui/downloads ──┤        │                                    │
│  ui/pwd_query ──┘        ▼                                    │
│                    core/models / remote_config                │
│                                                              │
│  core/download_manager ── core/gopeed_engine ── core/storage  │
└──────────────┬───────────────────────────┬───────────────────┘
               │ MethodChannel             │ HTTP 127.0.0.1
               ▼                           ▼
┌──────────────────────────────┐  ┌────────────────────────────┐
│ Android                       │  │ Windows                     │
│  GopeedBridge → Mobile.start  │  │  Process.start(gopeed-rest) │
│  StorageBridge → 权限/目录     │  │  stdout: GOPEED_PORT=<port> │
│  WebViewBridge → 内核版本      │  │  taskkill 清理残留进程       │
└──────────────────────────────┘  └────────────────────────────┘
               │
               ▼
      Gopeed Engine (Go)  ── bolt 任务元数据 + 多连接下载
```

设计要点：

1. **业务逻辑零平台分支**：除 `gopeed_engine.dart` 与 `storage_service.dart` 内的少量
   `Platform.isWindows` 判断外，全部 Dart 代码在两端复用。
2. **单例 + 全局状态**：`RequestSigner`、`DownloadManager`、`GopeedEngine`、`StorageService`
   均为进程级单例，避免多份引擎/通道状态。
3. **错误分层**：`ParseException`（业务/网络，message 可直接展示）与
   `GopeedApiException`（引擎层，`isConnectionError` 区分是否触发自愈）。
4. **配置驱动 UI**：`ParseConfig` 决定是否显示 token 输入、公告、Hero、线程数、体积限制。

---

## 接口与签名

### 基础约定

- 默认 BaseURL：`https://mf.dg22.top/api/v1`（可被远程配置 `parseApiBase` 覆盖）
- 超时：30 秒；请求头：`Accept: application/json, text/plain, */*`、`Content-Type: application/json`
- GET 参数走 query，POST 参数走 JSON body
- 响应结构：`{code, message, data}`，`code != 200` 视为业务失败

### 签名算法

站点前端在 axios 请求拦截器中对每个业务对象追加三个字段：

```dart
rand1 = SHA1( jsonEncode(业务字段，按插入顺序) )   // 40 位小写十六进制
rand2 = 32 位 hex 设备指纹                        // 首次生成后持久化
rand3 = SHA1(rand2)
```

关键实现（[signature.dart](lib/core/signature.dart)）：

```dart
Future<Map<String, dynamic>> sign(Map<String, dynamic> payload) async {
  final body = Map<String, dynamic>.of(payload);
  final rand1 = sha1Hex(jsonEncode(body));   // 必须先算，再插入签名字段
  final rand2 = await fingerprint();          // SharedPreferences: client_fingerprint_v1
  body['rand1'] = rand1;
  body['rand2'] = rand2;
  body['rand3'] = sha1Hex(rand2);
  return body;
}
```

> 设备指纹必须稳定且长度恰为 32 位；长度不符会重新生成并覆盖持久化值。

### 接口清单

| 方法 | 路径 | 入参 | 返回 `data` |
| --- | --- | --- | --- |
| GET | `/user/parse/config` | `token` | 站点配置（见下表） |
| GET | `/user/parse/limit` | `token` | `{count, size, expires_at}` |
| POST | `/user/parse/get_file_list` | `url, surl, pwd, dir, parse_password, token` | `{list[], randsk, uk, shareid}` |
| POST | `/user/parse/get_vcode` | `parse_password` | `{hit_captcha, vcode_str, vcode_img}` |
| POST | `/user/parse/get_download_links` | `randsk, uk, shareid, fs_id[], dlink[], surl, dir, pwd, token, parse_password, vcode_str, vcode_input` | `[{message, filename, fs_id, ua, urls[]}]` |

`/user/parse/config` 字段（snake_case → 客户端）：

| 服务端字段 | 类型 | 默认 | 含义 |
| --- | --- | --- | --- |
| `download_threads` | int | 16 | 下载线程数，客户端 clamp 到 `[1, 512]` |
| `show_token_input` | bool | true | 是否显示 token 输入框 |
| `show_extracted_link_input` | bool | true | 是否显示直链输入 |
| `show_announce` | bool | true | 是否显示公告 |
| `announce` | string(HTML) | '' | 公告正文，展示前去标签 |
| `custom_button` | string | '' | 自定义按钮，每行 `名称\|URL` |
| `show_hero` | bool | false | 是否显示 Hero 区 |
| `name` | string | '' | 站点名 |
| `logo` | string | `/favicon.ico` | Logo |
| `debug` | bool | false | 调试开关 |
| `max_once` | int | 0 | 单次最多解析文件数（0 不限） |
| `min_single_filesize` | int | 0 | 单文件最小体积（字节） |
| `max_single_filesize` | int | 0 | 单文件最大体积（字节） |
| `max_all_filesize` | int | 0 | 单次总体积上限（字节） |
| `allow_folder` | bool | false | 是否允许解析文件夹 |
| `need_password` | bool | false | 是否需要解析密码 |
| `have_account` | bool | true | 站点是否具备可用账号 |

### 限流与错误映射

```dart
// 429：最多重试 2 次，按 Retry-After 退避（缺省 3s，clamp 1..10）
if (response.statusCode == 429) {
  if (attempt < _maxRetry) {
    await Future.delayed(_retryAfter(response));
    continue;
  }
  throw const ParseException('访问过于频繁，请等几秒后重试');
}
```

| 场景 | 抛出 |
| --- | --- |
| 请求超时 | `ParseException('请求超时，请检查网络后重试')` |
| 其它网络异常 | `ParseException('网络请求失败：...')` |
| HTTP ≥ 400 | `ParseException(message ?? '请求失败（HTTP xxx）')` |
| 响应含 `SourceGuardian` | `ParseException('服务端缺少 SourceGuardian 组件，请稍后重试')` |
| `code != 200` | `ParseException(message, code: code)` |
| `message` 含 `-20` | `needCaptcha == true` → 触发图形验证码流程 |

---

## 远程配置

接口：`GET https://ai.yodlx.com/api/app2/config.php`（公开只读，8 秒超时）

响应兼容 `{code, data:{...}}` 与裸对象两种形态；结果缓存于进程内（`RemoteConfigService.cached`），
手动刷新时传 `useCache: false`。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `parseApiBase` | string | 解析站接口域名，空则回落 `https://mf.dg22.top/api/v1` |
| `announcement` | string | 首页公告，空则用内置兜底文案 |
| `parsePassword` | string | 站点解析密码，用户无需手填 |
| `pwdSiteUrl` | string | 密码查询站地址，空则 `https://mmhq.dg22.top/` |
| `pwdFirstPassword` | string | 密码查询站第一层密码，空则 `凝视深渊` |
| `popup` | object | 首页启动弹窗 |
| `pwdPopup` | object | 密码查询页说明弹窗（独立于 `popup`） |

弹窗结构：

```json
{
  "enabled": true,
  "title": "公告标题",
  "content": "正文（支持 \\n 换行）",
  "actionType": "none | link | qq",
  "actionLabel": "按钮文案",
  "actionValue": "URL 或 QQ 群号",
  "dismissible": true
}
```

- `actionType = qq` 时通过 `mqqapi://card/show_pslcard?...&uin=<群号>` 拉起 QQ；
  拉起失败则复制群号到剪贴板。
- `dismissible = false` 且存在动作按钮时，弹窗只能通过按钮关闭（强制引导）。
- 文案中的字面量 `\n` / `\r\n` 会被 `normalizeLineBreaks()` 统一转成真实换行。

---

## Gopeed 下载引擎

### 启动参数

```json
{
  "network": "tcp",
  "address": "127.0.0.1:0",
  "refreshInterval": 350,
  "storage": "bolt",
  "downloadConfig": {
    "downloadDir": "<下载目录>",
    "maxRunning": 3
  }
}
```

- `address` 端口为 `0` 表示由系统随机分配，避免端口冲突。
- Android 侧 `GopeedBridge.injectStorageDir()` 会补上 `storageDir = filesDir/gopeed`，
  保证 bolt 任务库可持久化（否则重启后任务列表丢失）。
- Windows 侧引擎以 `--storage <APPDATA>/com.liuguang.bdmfjx/gopeed --download <dir> --max 3`
  启动，并把 `GOPEED_PORT=<port>` 打印到 stdout。

### REST API（`http://127.0.0.1:<port>/api/v1`）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/tasks` | 创建任务，返回任务 id（字符串） |
| GET | `/tasks` | 任务列表（用于恢复与存活探测） |
| GET | `/tasks/{id}` | 任务详情（`status` / `progress` / `meta` / `error`） |
| PUT | `/tasks/{id}/pause` | 暂停 |
| PUT | `/tasks/{id}/continue` | 继续 |
| DELETE | `/tasks/{id}?force=true` | 删除任务（`force` 同时删除文件） |

响应统一为 `{code, msg, data}`，`code != 0` 抛 `GopeedApiException`。

### 状态映射

| 引擎 `status` | 客户端枚举 | UI 文案 |
| --- | --- | --- |
| `ready` / 其它 | `ready` | 准备中 |
| `running` | `running` | 下载中 |
| `wait` | `waiting` | 排队中 |
| `pause` | `paused` | 已暂停 |
| `error` | `error` | 失败 |
| `done` | `done` | 已完成 |

### 自愈机制

```
_started && _port != null
  └─ _isEngineAlive()  → GET /tasks
       ├─ 成功 / 业务错误 → 认为存活，复用端口
       └─ 连接类错误（SocketException / ClientException / Timeout）
            └─ forceReset() → 重新 start()（Windows 会 taskkill 残留进程）
```

下载创建时同样如此：连接类错误 → `forceReset()` → `_ensureEngine()` → 仅重试一次。

### 文件名推导

百度直链的真实文件名在 `outname=` 查询参数中，路径段只是文件 id：

```dart
static String? fileNameFromUrl(String url) {
  final outname = RegExp(r'[?&]outname=([^&]+)').firstMatch(url);
  if (outname != null) {
    final decoded = Uri.decodeComponent(outname.group(1)!.replaceAll('+', ' '));
    if (decoded.trim().isNotEmpty) return decoded.trim();
  }
  // 兜底：URL 路径最后一段
}
```

界面展示名与实际落盘名共用此逻辑，避免「看到的名字」与「下载后的名字」不一致。

---

## WebView 密码查询

站点（`pwdSiteUrl`）首屏是 Cloudflare Turnstile 人机验证，纯 HTTP 客户端无法通过，
因此内置 WebView 让用户完成验证后自动抓取解析密码。

### 限制与降级

| 常量 | 值 | 行为 |
| --- | --- | --- |
| `kMinWebViewMajor` | 70 | 内核主版本低于此值 → 直接提示升级内核（Turnstile 无法通过） |
| `kHybridCompositionBelowMajor` | 86 | 低于此值 → `displayWithHybridComposition: true`（规避 SurfaceTexture 黑屏/花屏） |
| `kUcUserAgent` | UC UA 模板 | 站点只放行 UC UA，其它一律 403；构建时把 `Chrome/123.0.6312.80` 替换为真实内核版本 |
| `kWebViewStoreUrl` | Play 商店 | 引导用户升级 Android System WebView |

另需 `_enableThirdPartyCookies()`：Cloudflare 的 `cf_clearance` Cookie 为第三方上下文，
不开启会导致验证反复失败。

### 注入脚本

JS 桥名 `TfPwdBridge`，页面本身是单页三步流程，三步 DOM 从加载起就全部存在，
仅通过容器内联 `style.display` 切换显隐：

| 步骤 | 容器 | App 行为 |
| --- | --- | --- |
| 1 | `#stepTurnstile` | 用户手动完成 Turnstile 验证 |
| 2 | `#stepPassword` | 自动填入第一层密码并提交 |
| 3 | `#stepResult` | 读取页面变量 `currentParsePwd` 的明文，通过桥回传 |

关键约束：

- **只读 `style.display` 判断当前步骤**：App 注入的样式脚本把整页 `visibility` 设为 `hidden`，
  读计算样式会全部落空。
- **只在结果步读取结果**：密码输入框与 UC 口令从加载起就在 DOM 中，
  提前读取会把验证码页误判成结果页，导致结果面板盖住验证码。
- **自动提交节流**：「距页面加载 1.5 秒 + 距上次同类提交 6 秒」，并用 `sessionStorage` 记录；
  自动提交上限 `TS_MAX = 2`、`PWD_MAX = 2`，超出后交给右上角「重新加载」。
- **Cloudflare 全页挑战识别**：标题含 `Just a moment` / `Attention Required`、
  `#challenge-form`、`Enable JavaScript and cookies to continue` 等 → 通知 App 展示提示。

### 结果页掩码与本地解密（1.2.8 修复）

站点在结果页改成了「只显示掩码」，明文不再出现在 DOM 里：

```js
var currentParsePwd = '';            // 明文仅存于页面内存
...
pwdEl.innerText = '••••••••••';      // #pwdValue 恒为掩码，仅供复制按钮
```

密码本身由 `POST ?api=get_pwd` 下发**加密 payload**，页面用 WebCrypto 在本地解密：

| 版本 | 密钥派生 |
| --- | --- |
| v1 | `SHA256(cs_token + '|' + ts + '|' + PEPPER_PART1 + PEPPER_PART2)` |
| v2 | `SHA256(cs_token + '|' + ts + '|' + PEPPER2_PART1 + PEPPER2_PART2 + '|' + envSig)` |

`envSig` 是 7 位环境签名，逐项检查 `navigator.webdriver` 与
`Function.prototype.toString` / `crypto.subtle.digest` / `importKey` / `decrypt` /
`atob` / `TextDecoder.prototype.decode` 是否为原生实现；页面加载时快照，
解密时重算比对，不一致就把签名反转 → 派生错误密钥 → **静默解出乱码或失败**。

修复前 `pickPwd()` 直接读 `#pwdValue` 的文本，于是把这串 `••••••••••` 当成解析密码
回传到 App，界面上就只剩一排黑色圆点。现在的取值顺序：

1. `sitePwd()`：先读页面全局变量 `currentParsePwd`（`var` 与顶层 `let` 都覆盖，
   `let` 不挂 `window`，故先用裸标识符探测再退回 `window` 属性）；
2. DOM 兜底：变量尚未写入（解密进行中）时读 `#pwdValue`；
3. `isMask()`：`•` / `·` / `‣` / `●` / `○` / `*` / `･` / `・` 及空串一律判为掩码，
   直接返回空，避免把圆点当结果。

因此**绝不能 hook 任何 WebCrypto 方法**（会改变 `Function.prototype.toString`
与 `crypto.subtle.*` 的原生特征，导致环境签名不一致、解密静默失败）。

抓到的密码会通过 `onPasswordCaptured` 回调**即时**写回首页（用户直接返回也不丢），
返回时再用页面结果兜底一次。

> `PwdQueryPage.isSupported` 仅在 Android / iOS / macOS 为 true；Windows 桌面端提示手动填写。

---

## 存储与权限

### 目录优先级

1. 用户自定义目录（`download_dir_custom`，需可写）
2. 系统公共下载目录（Android `/storage/emulated/0/Download/`）
3. 应用专属目录（无需权限，永远可写）
   - Android：`getExternalFilesDir(DIRECTORY_DOWNLOADS)`，退化为 `filesDir`
   - 其它平台：`Documents/TierFlowDownloads`

### 可写性校验

```dart
// Android：走 StorageBridge.ensureDir（mkdirs + 写入探针）
// 其它平台：Dart 侧 mkdir + 写入 .tierflow_write_probe 再删除
```

`setCustomDir()` 还会校验 `SharedPreferences.setString` 的**返回值**——
部分平台落盘失败只返回 `false` 而不抛异常，不校验会出现「提示成功、重启后恢复默认」的假成功。

### Android 版本差异

| API | 方案 |
| --- | --- |
| 24–28 | 运行时申请 `WRITE_EXTERNAL_STORAGE` |
| 29 | manifest `requestLegacyExternalStorage="true"`，仍需运行时权限 |
| 30+ | `MANAGE_EXTERNAL_STORAGE`（所有文件访问），跳系统设置页手动开启 |

Manifest 权限：

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29"/>
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>
<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE" tools:ignore="ScopedStorage"/>
```

其它 manifest 要点：

- `android:usesCleartextTraffic="true"`：引擎走 `http://127.0.0.1`。
- `<queries>` 声明 `com.tencent.mobileqq`、`mqqapi://`、`https://`：
  Android 11+ 包可见性限制下，未声明会导致弹窗「一键加群」点击无响应。
- `jniLibs { useLegacyPackaging = true }`：引擎 `.so` 需解压到磁盘后再加载。

---

## 构建与发布

### Android

```bash
flutter build apk --release --target-platform android-arm64
```

关键配置（`android/app/build.gradle.kts`）：

```kotlin
defaultConfig {
    applicationId = "com.liuguang.bdmfjx"
    ndk { abiFilters.clear(); abiFilters.add("arm64-v8a") }
}
buildTypes {
    release {
        signingConfig = signingConfigs.getByName("debug")  // 当前使用 debug 签名
        isMinifyEnabled = false      // Go 引擎反射/序列化路径不能被混淆
        isShrinkResources = false
    }
}
packaging { jniLibs { useLegacyPackaging = true } }
dependencies { implementation(files("libs/libgopeed.aar")) }
```

- 版本号来自 `pubspec.yaml` 的 `version: 1.2.8+11`（`versionName=1.2.8`，`versionCode=11`）。
- **发布到应用商店前必须替换为自己的 release keystore**，debug 签名不可用于正式分发。

### Windows

```bash
flutter build windows --release
```

`windows/runner/CMakeLists.txt` 在链接后自动把引擎复制到可执行文件目录：

```cmake
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/gopeed-rest.exe"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/gopeed-rest.exe"
  COMMENT "Copying gopeed-rest.exe engine")
```

分发时需打包整个 `Release/` 目录（`tierflow.exe`、`gopeed-rest.exe`、`data/`、DLL）。

---

## 测试

```bash
flutter analyze
flutter test
```

现有用例（`test/widget_test.dart`）：

- `parseShareLink`：标准链接 / 混合文本提取提取码 / 无链接判无效
- `RequestSigner.sha1Hex`：`abc` 与空串的标准 SHA-1 向量

---

## 版本历史

| 版本 | 主要变更 |
| --- | --- |
| 1.2.8 | 当前版本；下载目录假成功修复、引擎连接中断自愈、密码查询页稳定性；**修复解析密码显示为圆点**（站点改为掩码 + 本地解密，改读 `currentParsePwd`） |
| 1.2.x | WebView 密码查询（Turnstile 三步流程、老内核降级/升级引导） |
| 1.1.x | 内嵌 Gopeed 引擎、断点续传、下载任务页、远程配置下发 |
| 1.1.0 | 首个可用版本：分享链接解析、文件列表、直链下载 |
| 1.0.0 | 项目初始化 |

---

## 常见问题

**Q：解析提示「尚未获取解析密码」？**
点击右上角钥匙图标进入密码查询页，完成 Turnstile 验证后会自动回填；也可等待远程配置下发。

**Q：提示「访问过于频繁」？**
站点位于 Cloudflare 后方，短时间连发会 429。客户端已按 `Retry-After` 自动重试 2 次，
仍失败请等待几秒再操作，并减少单次勾选的文件数量。

**Q：下载任务创建失败 / 进度不刷新？**
先在「下载任务」页确认引擎状态。连接类错误客户端会自动重启引擎并重试一次；
Windows 端若有残留进程，重启 App 时会自动 `taskkill /IM gopeed-rest.exe /F`。

**Q：Android 11+ 下载不到公共 Download 目录？**
需要「所有文件访问」权限：任务页 → 目录设置 → 去授权，在系统设置中开启后返回。
若不授权，客户端会自动回退到应用专属目录（同样可正常下载）。

**Q：Windows 端密码查询页不可用？**
`webview_flutter` 仅在 Android / iOS / macOS 提供实现，桌面端请手动填写解析密码。

**Q：构建时提示找不到 `gradlew`？**
仓库的 `android/.gitignore` 忽略了 Gradle wrapper，执行 `flutter create .` 重新生成即可。

**Q：APK 为什么只支持 arm64？**
`libgopeed.aar` 只提供 `arm64-v8a` 预编译产物，`abiFilters` 已限制为 arm64；
x86 模拟器无法安装。

---

## 深入文档

| 文档 | 内容 |
| --- | --- |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 分层架构、模块职责、时序图、状态机、错误处理与自愈设计 |
| [docs/API.md](docs/API.md) | 解析站接口、签名算法、数据模型、远程配置、Gopeed REST 完整参考 |
| [docs/BUILD.md](docs/BUILD.md) | 环境准备、Android/Windows 构建、签名、发版检查清单、故障排查 |

---

## License

本项目仅用于学习研究，未声明开源许可证。在获得作者书面许可前，请勿用于商业用途或二次分发。
