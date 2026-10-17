# 接口参考

> 项目：百度网盘不限大小不限速解析（`baidujiexi`）
> 版本基线：`1.2.8+11`

本文档给出三类对外接口的完整参考：

1. **远程配置接口**（自有后端 `ai.yodlx.com`）—— 启动时下发运行参数。
2. **解析站接口**（`mf.dg22.top`）—— 分享链接解析，含请求签名。
3. **Gopeed REST 接口**（`127.0.0.1:<随机端口>`）—— 本机下载引擎。

> 所有响应结构与字段均以客户端实际解析逻辑（`lib/core/*.dart`）为准。服务端字段缺失时客户端有默认值兜底，下表「必填」列描述的是「缺失会影响功能」而非「服务端强制」。

---

## 目录

- [1. 远程配置接口](#1-远程配置接口)
- [2. 解析站接口](#2-解析站接口)
  - [2.1 基础约定](#21-基础约定)
  - [2.2 请求签名](#22-请求签名)
  - [2.3 统一响应与错误](#23-统一响应与错误)
  - [2.4 GET /user/parse/config](#24-get-userparseconfig)
  - [2.5 GET /user/parse/limit](#25-get-userparselimit)
  - [2.6 POST /user/parse/get_file_list](#26-post-userparseget_file_list)
  - [2.7 POST /user/parse/get_vcode](#27-post-userparseget_vcode)
  - [2.8 POST /user/parse/get_download_links](#28-post-userparseget_download_links)
- [3. 数据模型](#3-数据模型)
- [4. Gopeed REST 接口](#4-gopeed-rest-接口)
- [5. 分享链接解析规则](#5-分享链接解析规则)
- [6. 错误码与处理策略](#6-错误码与处理策略)

---

## 1. 远程配置接口

### 1.1 请求

```
GET https://ai.yodlx.com/api/app2/config.php
```

- 无参数、无需鉴权、无自定义请求头。
- 客户端超时：**8 秒**（`RemoteConfigService._timeout`）。
- 进程内缓存：首次成功后写入静态字段 `_cached`，后续 `load()` 默认直接命中缓存；`load(useCache: false)` 强制重新请求（启动页「重试」走这条路径）。
- 失败策略：**任何异常都返回 `null`**，不阻断启动，调用方回落到内置默认值。

### 1.2 响应格式

兼容两种形态，客户端先取 `data`，若不是对象则把整个响应体当作配置对象：

```json
{
  "code": 200,
  "data": {
    "parseApiBase": "https://mf.dg22.top/api/v1",
    "announcement": "本站免费提供解析服务",
    "parsePassword": "xxxx",
    "pwdSiteUrl": "https://mmhq.dg22.top/",
    "pwdFirstPassword": "凝视深渊",
    "popup": { },
    "pwdPopup": { }
  }
}
```

或裸对象：

```json
{
  "parseApiBase": "https://mf.dg22.top/api/v1"
}
```

响应体按 **UTF-8** 解码（`utf8.decode(response.bodyBytes)`），避免中文乱码。

### 1.3 字段

| 字段 | 类型 | 缺省 | 说明 |
| --- | --- | --- | --- |
| `parseApiBase` | string | `''` | 解析站接口根地址。**为空时客户端保留内置默认值** `https://mf.dg22.top/api/v1`；非空则整体覆盖（需带 `/api/v1`）。所有字段值都会 `trim()`。 |
| `announcement` | string | `''` | 首页公告。为空则不展示。 |
| `parsePassword` | string | `''` | 解析站要求的解析密码，客户端自动携带，用户无需输入。为空则回落到弹窗手动输入 / 密码查询页。 |
| `pwdSiteUrl` | string | `''` | 密码查询站地址。为空则用内置 `https://mmhq.dg22.top/`。 |
| `pwdFirstPassword` | string | `''` | 密码查询站第一层密码。为空则用内置 `凝视深渊`。 |
| `popup` | object | `{}` | 首页运营弹窗，结构见 1.4。 |
| `pwdPopup` | object | `null` → 内置兜底 | 「获取解析密码」页专用弹窗，结构同 1.4；未下发时使用 `kFallbackPwdPopup`。 |

### 1.4 弹窗对象 `AppPopup`

| 字段 | 类型 | 缺省 | 说明 |
| --- | --- | --- | --- |
| `enabled` | bool | `false` | 是否启用。**必须严格等于 `true`**（`json['enabled'] == true`），字符串 `"true"` 不生效。 |
| `title` | string | `''` | 标题。 |
| `content` | string | `''` | 正文，支持换行。 |
| `actionType` | string | `'none'` | 按钮行为：`none` 无按钮 / `link` 打开链接 / `qq` 复制 QQ 号。 |
| `actionLabel` | string | `''` | 按钮文案。 |
| `actionValue` | string | `''` | 按钮目标（URL 或 QQ 号）。 |
| `dismissible` | bool | `true` | 是否允许点遮罩/返回键关闭。仅 `false` 时禁止关闭。 |

**展示条件**

- `isVisible` = `enabled && (content 非空 || title 非空)`
- `hasAction` = `actionType != 'none' && actionLabel 非空 && actionValue 非空`

`qq` 类型通过 `mqqapi://card/show_pslcard?src_type=internal&version=1&uin=<QQ号>` 唤起 QQ，因此 Android 的 `AndroidManifest.xml` 声明了对应 `<queries>`。

---

## 2. 解析站接口

### 2.1 基础约定

| 项 | 值 |
| --- | --- |
| Base URL | `https://mf.dg22.top/api/v1`（可被 `parseApiBase` 覆盖） |
| 请求头 | `Accept: application/json, text/plain, */*`、`Content-Type: application/json` |
| 超时 | 30 秒 |
| GET 参数 | 全部平铺到 query string，值统一 `toString()` |
| POST 参数 | JSON body |
| 鉴权 | `token` 字段（默认 `guest`，持久化键 `parse_token`） |
| 前置 | 站点位于 Cloudflare 后，可能返回 429 |

### 2.2 请求签名

站点的 axios 请求拦截器会为每个业务对象追加三个字段。客户端在 `RequestSigner.sign` 中等价实现：

```dart
final body = Map<String, dynamic>.of(payload);
final rand1 = sha1Hex(jsonEncode(body));   // 业务字段的 JSON 字符串
final rand2 = await fingerprint();          // 32 位 hex 设备指纹
body['rand1'] = rand1;
body['rand2'] = rand2;
body['rand3'] = sha1Hex(rand2);
```

**计算顺序（关键）**

```
1. 组装业务字段（含 token），得到 payload
2. rand1 = SHA1( jsonEncode(payload) )        ← 此时 payload 中还没有 rand*
3. rand2 = 持久化的 32 位十六进制指纹
4. rand3 = SHA1( rand2 )
5. 依次写入 rand1 → rand2 → rand3
```

**陷阱清单**

1. **`rand1` 必须在写入 `rand1/rand2/rand3` 之前算**。若先插入字段再算，哈希输入就被污染，服务端校验必然失败。
2. **键顺序会影响 `jsonEncode` 结果**。Dart 的 `Map` 保持插入顺序，因此 `payload` 的键顺序必须与服务端期望一致：先业务字段、再加签名。`Map<String, dynamic>.of(payload)` 会复制并保留顺序，不要在多处复用被修改过的同一个 Map。
3. **`rand2` 必须是 32 位**。`fingerprint()` 读 `SharedPreferences` 键 `client_fingerprint_v1`，长度不是 32 就重新生成；生成源是 `Random.secure()` 的十六进制串，一旦写入永久复用。
4. **GET 也签名**。签名字段作为 query 参数随请求发出，值需转字符串。
5. **JSON 序列化不含空格**。Dart `jsonEncode` 输出紧凑格式，不要手动拼接带空格/换行的 JSON。

**指纹生成**

```dart
static String _randomHex(int length) {
  const chars = '0123456789abcdef';
  final random = Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < length; i++) {
    buffer.write(chars[random.nextInt(chars.length)]);
  }
  return buffer.toString();
}
```

`rand2` 模拟浏览器 FingerprintJS 的 visitorId：同一设备首次生成后固定，卸载重装会变。

### 2.3 统一响应与错误

成功响应体：

```json
{ "code": 200, "message": "ok", "data": { } }
```

客户端解析顺序（`_send`）：

1. HTTP 429 → 退避重试（最多 2 次），仍失败抛「访问过于频繁」。
2. `statusCode >= 400` → 抛 `ParseException(message 或 HTTP 状态)`。
3. 响应体为空 → 视为 `{}`。
4. 非 JSON（`jsonDecode` 失败）→ 保留原始字符串。
5. 原始字符串包含 `SourceGuardian` → 抛「服务端缺少 SourceGuardian 组件」。
6. 非 Map → 抛「服务器返回格式异常」。
7. `code != null && code != 200` → 抛 `ParseException(message, code: code)`。
8. 通过 → 返回整个 Map，调用方从 `data` 取数据。

**429 退避**

```dart
final seconds = int.tryParse(response.headers['retry-after'] ?? '');
return Duration(seconds: (seconds ?? 3).clamp(1, 10));
```

- `Retry-After` 缺失或非数字 → 3 秒
- 小于 1 秒 → 按 1 秒
- 大于 10 秒 → 按 10 秒

---

### 2.4 GET /user/parse/config

站点配置，决定 UI 展示与下载策略。

**请求**

| 参数 | 位置 | 类型 | 说明 |
| --- | --- | --- | --- |
| `token` | query | string | 解析 token，默认 `guest` |

**响应 `data`**

| 字段 | 类型 | 缺省 | 说明 |
| --- | --- | --- | --- |
| `download_threads` | int | `16` | 单文件下载线程数，客户端 `clamp(1, 512)` |
| `show_token_input` | bool | `true` | 是否展示 token 输入框 |
| `show_extracted_link_input` | bool | `true` | 是否展示直链输入框 |
| `show_announce` | bool | `true` | 是否展示公告 |
| `announce` | string | `''` | 公告内容（可含 HTML，展示前剥标签） |
| `custom_button` | string | `''` | 自定义按钮，多行 `名称\|URL` |
| `show_hero` | bool | `false` | 是否展示 Hero 区 |
| `name` | string | `''` | 站点名称 |
| `logo` | string | `'/favicon.ico'` | Logo 地址 |
| `debug` | bool | `false` | 调试开关 |
| `max_once` | int | `0` | 单次最多解析文件数，`0` 不限 |
| `min_single_filesize` | int | `0` | 单文件最小体积（字节），`0` 不限 |
| `max_single_filesize` | int | `0` | 单文件最大体积（字节），`0` 不限 |
| `max_all_filesize` | int | `0` | 单次总体积上限（字节），`0` 不限 |
| `allow_folder` | bool | `false` | 是否允许解析文件夹 |
| `need_password` | bool | `false` | 是否需要解析密码 |
| `have_account` | bool | `true` | 站点是否配置了网盘账号 |

**类型容错**：布尔字段接受 `bool` / `num`（非 0 为真）/ `string`（仅 `"true"` 忽略大小写为真）；整型字段接受任意 `num`。

**辅助派生**

- `buttons`：把 `custom_button` 按行拆分，仅接受含 `|` 且两侧均非空的行。
- `plainAnnounce`：`announce` 去掉 HTML 标签、压缩连续空白。

---

### 2.5 GET /user/parse/limit

查询剩余配额。

**请求**：`token`（query）。

**响应 `data`**

| 字段 | 类型 | 缺省 | 说明 |
| --- | --- | --- | --- |
| `count` | int | `0` | 剩余可解析次数 |
| `size` | int | `0` | 剩余可解析体积（字节） |
| `expires_at` | string | `'1970-01-01 08:00:00'` | 配额到期时间 |

---

### 2.6 POST /user/parse/get_file_list

拉取分享目录（也可用于下钻子目录）。

**请求体**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `url` | string | 是 | 完整分享链接，**带 `?pwd=`**（若已知提取码） |
| `surl` | string | 是 | `/s/` 之后的分享 id，**必须含首位 `1`**，否则百度返回 `errno -130` |
| `pwd` | string | 是 | 分享提取码；无提取码传空串 |
| `dir` | string | 是 | 目录路径，根目录为 `/` |
| `parse_password` | string | 是 | 站点要求的解析密码 |
| `token` | string | 是 | 解析 token |

**响应 `data`**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `list` | array | 目录项数组，见下 |
| `randsk` | string | 后续 `get_download_links` 必填凭据 |
| `uk` | string | 用户 id 凭据 |
| `shareid` | string | 分享 id 凭据 |

**`list[]` 项**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `category` | int | 文件类别 |
| `fs_id` | int | 文件 id，解析直链时必填 |
| `is_dir` | bool | 是否目录。目录项跳过直链解析，改为下钻 |
| `size` | int | 字节数 |
| `md5` | string | 文件 MD5 |
| `path` | string | 完整路径 |
| `server_filename` | string | 展示用文件名 |
| `dlink` | string | 服务端下发的下载链接字段，原样回传给 `get_download_links` |

**注意**：`list` 中非 Map 的元素会被静默跳过，不抛异常。

---

### 2.7 POST /user/parse/get_vcode

获取图形验证码。仅在业务错误信息包含 `-20` 时调用。

**请求体**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `parse_password` | string | 是 | 站点解析密码 |

> 该接口**不携带 `token`**，与其他接口不同。

**响应 `data`**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `hit_captcha` | bool | 是否命中验证码（客户端会强制置为 `true`） |
| `vcode_str` | string | 验证码会话标识，回传时原样带回 |
| `vcode_img` | string | 图片内容，支持 **base64** 或**相对路径**（客户端两种都处理） |

**使用流程**

```
业务接口抛 ParseException → needCaptcha == true
  └─ getVcode(parsePassword)
       └─ 弹窗展示图片 → 用户输入
            └─ 原业务接口重试，带 vcode_str + vcode_input
```

---

### 2.8 POST /user/parse/get_download_links

把选中文件解析为可下载直链。**一次请求可提交多个文件**（`fs_id` / `dlink` 为并行数组）。

**请求体**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `randsk` | string | 是 | 来自 `get_file_list` |
| `uk` | string | 是 | 来自 `get_file_list` |
| `shareid` | string | 是 | 来自 `get_file_list` |
| `fs_id` | int[] | 是 | 文件 id 数组，与 `dlink` 一一对应 |
| `dlink` | string[] | 是 | 文件下载链接数组 |
| `surl` | string | 是 | 分享 id |
| `dir` | string | 是 | 当前目录 |
| `pwd` | string | 是 | 分享提取码 |
| `token` | string | 是 | 解析 token |
| `parse_password` | string | 是 | 站点解析密码 |
| `vcode_str` | string | 否 | 验证码会话标识，无验证码传空串 |
| `vcode_input` | string | 否 | 用户输入的验证码，无验证码传空串 |

**响应 `data`**

对象数组，每项：

```json
[
  {
    "message": "",
    "filename": "示例文件.mp4",
    "fs_id": 123456789,
    "ua": "netdisk;P2SP;2.2.60.26",
    "urls": [
      "https://d.pcs.baidu.com/file/...?outname=xxx&...",
      "https://d.pcs.baidu.com/file/...?..."
    ]
  }
]
```

**客户端展开规则**（`DirectLink.parseList`）

1. `data` 为数组：遍历每个对象，读取 `ua`、`filename`，展开 `urls` 中每个非空字符串为一条 `DirectLink`，共享同一 `ua` 与 `name`。
2. `urls` 非数组 → 跳过该项。
3. `data` 为**非空字符串** → 视为单条直链（兼容旧版返回）。
4. `data` 为其它类型 → 返回空列表。

**下载约束**：`ua` 必须作为下载请求的 `User-Agent` 透传给引擎，否则百度拒绝。客户端在 `_downloadWithEngine` 中只透传 `{'User-Agent': ua}`。

---

## 3. 数据模型

### 3.1 `ShareLink`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `url` | string | 规范化后的完整链接，有提取码时带 `?pwd=` |
| `surl` | string | `/s/` 之后的分享 id |
| `pwd` | string | 提取码，可能为空 |
| `isValid` | bool | `surl` 非空 |

### 3.2 `FileItem` / `FileListData`

见 2.6。`FileListData` 构造要求 `list/randsk/uk/shareid` 全部存在（缺失时为空值）。

### 3.3 `DirectLink`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `url` | string | 真实直链 |
| `name` | string | 服务端 `filename`，可能为空 |
| `ua` | string | 下载所需 UA，可能为空 |

### 3.4 `VcodeInfo`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `hitCaptcha` | bool | 是否触发验证码 |
| `vcodeStr` | string | 回传标识 |
| `vcodeImg` | string | base64 或相对路径 |
| `vcodeInput` | string | 用户输入（仅本地） |

### 3.5 `ParseConfig` / `LimitInfo` / `AppPopup` / `CustomButton`

见第 1、2 节字段表。`ParseConfig` 为不可变值对象，所有字段在构造时给定默认值，`fromJson` 只做读取与类型转换，不做业务校验（唯一例外是 `downloadThreads` 的 `clamp(1, 512)`）。

---

## 4. Gopeed REST 接口

### 4.1 连接信息

| 项 | Android | Windows |
| --- | --- | --- |
| 启动方式 | MethodChannel `start` → `Mobile.start(configJson)` | 子进程 `gopeed-rest.exe` |
| 监听地址 | `127.0.0.1:0`（由引擎分配） | 同左 |
| 端口获取 | 原生桥返回 int | 解析 stdout 的 `GOPEED_PORT=<port>` |
| Base URL | `http://127.0.0.1:<port>/api/v1` | 同左 |
| 请求超时 | 30 秒 | 30 秒 |

**启动配置**（Android 传给 `Mobile.start`）

```json
{
  "network": "tcp",
  "address": "127.0.0.1:0",
  "refreshInterval": 350,
  "storage": "bolt",
  "downloadConfig": {
    "downloadDir": "<解析后的下载目录>",
    "maxRunning": 3
  }
}
```

Windows 子进程参数：

```
gopeed-rest.exe --storage <APPDATA>\com.liuguang.bdmfjx\gopeed --download <下载目录> --max 3
```

**子进程协议**

| 输出行 | 含义 |
| --- | --- |
| `GOPEED_PORT=<port>` | 启动成功，端口号 |
| `GOPEED_ERROR=<msg>` | 启动失败，附错误信息 |

客户端并发消费 `stdout` 与 `stderr`（`stderr` 内容丢弃但必须消费，否则管道写满会阻塞子进程），任一分支先完成即决定结果；超时 20 秒返回 `-1`，最多尝试 2 次。启动前执行 `taskkill /IM gopeed-rest.exe /F` 清理残留进程。

### 4.2 通用响应

```json
{ "code": 0, "msg": "ok", "data": { } }
```

- `code != 0` 或 `statusCode != 200` → 抛 `GopeedApiException(statusCode, msg)`。
- 响应体为空 → 视作 `{}`，`data` 为 null。
- 连接类异常（`SocketException` / `http.ClientException` / `TimeoutException`）→ `isConnectionError = true`，`statusCode = -1`。

### 4.3 端点

| 方法 | 路径 | 说明 | 返回 `data` |
| --- | --- | --- | --- |
| `POST` | `/tasks` | 创建任务 | 任务 id（string） |
| `GET` | `/tasks` | 任务列表 | 任务对象数组 |
| `GET` | `/tasks/{id}` | 任务详情 | 任务对象 |
| `PUT` | `/tasks/{id}/pause` | 暂停 | — |
| `PUT` | `/tasks/{id}/continue` | 继续 | — |
| `DELETE` | `/tasks/{id}` | 删除任务；`?force=true` 同时删文件 | — |

### 4.4 创建任务

```http
POST /api/v1/tasks
Content-Type: application/json

{
  "req": {
    "url": "https://d.pcs.baidu.com/file/...",
    "extra": {
      "method": "GET",
      "header": {
        "User-Agent": "netdisk;P2SP;2.2.60.26"
      }
    }
  },
  "opts": {
    "name": "示例文件.mp4",
    "path": "/storage/emulated/0/Download",
    "extra": {
      "connections": 3
    }
  }
}
```

| 字段 | 说明 |
| --- | --- |
| `req.url` | 直链 |
| `req.extra.method` | HTTP 方法，固定 `GET` |
| `req.extra.header` | 透传请求头（UA / Cookie） |
| `opts.name` | 落盘文件名 |
| `opts.path` | 保存目录绝对路径 |
| `opts.extra.connections` | 单任务连接数，客户端固定 **3** |

> 注意：`download_threads`（默认 16）来自解析站配置，当前实现中任务连接数固定为 3，两者不联动。

### 4.5 任务对象（客户端读取的字段）

```json
{
  "id": "0a1b2c3d",
  "status": "running",
  "progress": {
    "downloaded": 10485760,
    "speed": 2097152
  },
  "meta": {
    "name": "示例文件.mp4",
    "req": { "url": "https://..." },
    "res": { "size": 104857600 }
  },
  "error": ""
}
```

| 字段 | 用途 |
| --- | --- |
| `id` | 任务标识，后续所有操作的 key |
| `status` | 状态字符串，映射规则见下 |
| `progress.downloaded` | 已下载字节 |
| `progress.speed` | 瞬时速度（字节/秒） |
| `meta.name` | 文件名（缺失时尝试顶层 `name`，再兜底「未命名」） |
| `meta.req.url` | 原始直链 |
| `meta.res.size` | 文件总大小，`> 0` 时才更新 `total` |
| `error` | 非空且非空串时作为错误文案 |

### 4.6 状态映射

| 引擎状态 | 客户端枚举 | 中文 | 终态 |
| --- | --- | --- | --- |
| `running` | `running` | 下载中 | 否 |
| `wait` | `waiting` | 排队中 | 否 |
| `pause` | `paused` | 已暂停 | 否 |
| `error` | `error` | 失败 | 是 |
| `done` | `done` | 已完成 | 是 |
| 其它 / 缺失 | `ready` | 准备中 | 否 |

### 4.7 轮询

- 周期 **800ms**，`Timer.periodic`。
- 每 tick 遍历**所有非终态任务**，逐个 `GET /tasks/{id}`。
- 全部任务进入终态时自动停止定时器；新增任务或暂停/继续时重新启动。
- 连接类错误：置 `_engineReady = false` 并写入「下载引擎连接中断」，下次建任务会触发引擎重启。

---

## 5. 分享链接解析规则

`parseShareLink(raw)` 从任意文本中提取分享信息。

**支持格式**

| 形式 | 示例 | 提取结果 |
| --- | --- | --- |
| 标准链接 | `https://pan.baidu.com/s/1AbCdEf` | `surl = 1AbCdEf` |
| 带提取码 | `https://pan.baidu.com/s/1AbCdEf?pwd=vD32` | `surl = 1AbCdEf`，`pwd = vD32` |
| WAP 链接 | `https://pan.baidu.com/wap/init?surl=1AbCdEf` | `surl = 1AbCdEf` |
| 文字描述 | `链接: ... 提取码：vD32` | 正则抓 4 位提取码 |

**规则细节**

1. 正则：`https?://pan\.baidu\.com/s/([A-Za-z0-9_-]+)`，`surl` **必须包含首位 `1`**，否则百度返回 `errno -130`。
2. `pwd` 优先取链接里的 `[?&]pwd=([^&\s]+)`。
3. 链接无 `pwd` 时，从文本匹配 `(?:提取码|访问码|密码|pwd)\s*[:：=]?\s*([A-Za-z0-9]{4})(?![A-Za-z0-9])`，要求恰好 4 位且后面不再跟字母数字。
4. 识别不到 `surl` 时返回 `{url: 原始文本, surl: '', pwd: ''}`，`isValid == false`，调用方据此提示用户。
5. 规范化后的 `url` 在有提取码时补 `?pwd=`，供 `get_file_list` 直接使用。

---

## 6. 错误码与处理策略

### 6.1 客户端错误类型

| 类型 | 触发点 | 处理 |
| --- | --- | --- |
| `ParseException` | 解析站所有失败 | 直接展示 `message` |
| `ParseException.needCaptcha` | `message` 包含 `-20` | 拉起图形验证码流程 |
| `GopeedApiException`（`isConnectionError = true`） | 端口不通 / 超时 | 引擎自愈重启（一次） |
| `GopeedApiException`（业务） | 引擎返回非 0 | 标记任务失败，展示 `msg` |
| `TimeoutException` | 请求超 30s | 转为「请求超时，请检查网络后重试」 |
| 其它异常 | 网络库/解析 | 转为「网络请求失败：<error>」 |

### 6.2 典型场景对照

| 现象 | 可能原因 | 客户端行为 |
| --- | --- | --- |
| 「访问过于频繁，请等几秒后重试」 | Cloudflare 429，且 2 次重试后仍限流 | 提示用户手动等待 |
| 「服务器返回了无法识别的数据」 | 响应体为 `null` 或不可解析 | 提示 |
| 「服务端缺少 SourceGuardian 组件」 | 响应含 `SourceGuardian` 字样 | 提示稍后重试 |
| 「请求失败（HTTP 5xx）」 | 服务端异常 | 展示服务端 `message` |
| 提示含 `-20` | 命中风控，需要验证码 | 自动弹验证码 |
| 「下载引擎连接中断」 | 引擎进程被杀死/崩溃 | 下次建任务自动重启引擎 |
| 「未找到 gopeed-rest.exe 引擎文件」 | Windows 构建缺少引擎 | 检查 `windows/runner/CMakeLists.txt` 的 POST_BUILD 复制 |
| 「Gopeed 引擎启动超时」 | 端口未被占用成功 / 被安全软件拦截 | 提示，日志看 `GOPEED_ERROR=` |

### 6.3 重试策略总览

| 层级 | 条件 | 次数 | 退避 |
| --- | --- | --- | --- |
| HTTP 429 | 解析站限流 | 2 | `Retry-After` clamp(1, 10)s，缺省 3s |
| 引擎启动（Windows） | 未拿到端口 | 2 | 立即，重试前 `taskkill` 清理 |
| 引擎自愈 | 连接类错误 | 1 | 立即 |
| 验证码 | `needCaptcha` | 由用户交互驱动，非自动重试 | — |
