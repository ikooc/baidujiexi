# 构建与发布

> 项目：百度网盘不限大小不限速解析（`baidujiexi`）
> 版本基线：`1.2.8+11`
> 目标平台：Android（arm64-v8a）、Windows（x64）

本文覆盖从零克隆到产物落地的完整流程，以及常见故障排查。架构说明见 [ARCHITECTURE.md](ARCHITECTURE.md)，接口细节见 [API.md](API.md)。

---

## 目录

- [1. 环境准备](#1-环境准备)
- [2. 拉取代码与依赖](#2-拉取代码与依赖)
- [3. Android 构建](#3-android-构建)
- [4. Windows 构建](#4-windows-构建)
- [5. 发布签名](#5-发布签名)
- [6. 发版检查清单](#6-发版检查清单)
- [7. 本机分发（可选）](#7-本机分发可选)
- [8. 故障排查](#8-故障排查)

---

## 1. 环境准备

### 1.1 必需组件

| 组件 | 版本要求 | 说明 |
| --- | --- | --- |
| Flutter SDK | **3.44.7 stable**（Dart 3.12.2） | `pubspec.yaml` 声明 `sdk: ^3.12.2` |
| JDK | **17** | `compileOptions` 与 `jvmTarget` 均为 17 |
| Android SDK | `compileSdk` / `targetSdk` 跟随 Flutter 默认；`minSdk` 跟随 Flutter 默认 | 需要 **NDK**（`ndkVersion = flutter.ndkVersion`） |
| Visual Studio | 2022，勾选「使用 C++ 的桌面开发」 | Windows 构建必需 |
| Git | 任意较新版本 | 拉取代码 |

### 1.2 版本校验

```bash
flutter --version
# Flutter 3.44.7 • channel stable
# Dart 3.12.2

flutter doctor -v
# 确认 Android toolchain / Visual Studio / Windows 桌面均打勾
```

### 1.3 项目内工具链版本

| 项 | 版本 | 位置 |
| --- | --- | --- |
| Android Gradle Plugin | 9.0.1 | `android/settings.gradle.kts` |
| Kotlin | 2.3.20 | `android/settings.gradle.kts` |
| Flutter Gradle Plugin | 1.0.0 | `android/settings.gradle.kts` |
| Gradle JVM 内存 | `-Xmx8G` | `android/gradle.properties` |
| Gradle Wrapper | 见 `android/gradle/wrapper/gradle-wrapper.properties` | — |

`android/gradle.properties` 中的关键开关：

```properties
org.gradle.jvmargs=-Xmx8G
android.useAndroidX=true
android.newDsl=false
android.builtInKotlin=false
```

> `android.newDsl=false` 与 `android.builtInKotlin=false` 是为了兼容 AGP 9 + Flutter Gradle 插件的现有写法，不要随意删除。

---

## 2. 拉取代码与依赖

```bash
git clone https://github.com/ikooc/baidujiexi.git
cd baidujiexi
flutter pub get
```

### 2.1 必需二进制（仓库内已包含）

| 文件 | 平台 | 大小 | 用途 |
| --- | --- | --- | --- |
| `android/app/libs/libgopeed.aar` | Android | 约 64.8 MB | Go 移动端绑定的下载引擎，提供 `com.gopeed.mobile.Mobile` |
| `windows/runner/gopeed-rest.exe` | Windows | 约 43.0 MB | 独立进程下载引擎，启动后打印 `GOPEED_PORT=` |

这两个文件**不可用 `flutter pub get` 自动获取**，必须随仓库分发。若缺失：

- Android 构建会在 `:app:mergeReleaseJavaResource` 或编译期报 `cannot find symbol: com.gopeed.mobile.Mobile`；
- Windows 运行时会提示「未找到 gopeed-rest.exe 引擎文件」。

### 2.2 Gradle Wrapper 缺失的处理

`android/.gitignore` 忽略了 `gradlew`、`gradlew.bat`、`gradle-wrapper.jar`。克隆后若 `android/gradlew` 不存在：

**方式 A（推荐）** 重新生成 wrapper：

```bash
cd android
gradle wrapper --gradle-version <与 gradle-wrapper.properties 一致>
```

**方式 B** 用 Flutter 补齐平台目录（会保留现有 `lib/`、`android/app/src/` 等文件，只补缺失脚手架）：

```bash
flutter create .
```

> 推荐方式 A，方式 B 可能覆盖部分平台配置，执行前先 `git status` 确认。

### 2.3 `android/local.properties`

该文件被忽略，首次构建时由 Flutter 自动生成，需包含 SDK 路径：

```properties
sdk.dir=C:\\Users\\<用户名>\\AppData\\Local\\Android\\Sdk
flutter.sdk=D:\\flutter
```

若构建报「SDK location not found」，手动补上述两行即可。

---

## 3. Android 构建

### 3.1 调试运行

```bash
flutter devices
flutter run -d <device-id>
```

仅支持 **arm64-v8a** 真机或 arm64 模拟器。x86_64 模拟器会在加载引擎 `.so` 时失败，因为 `libgopeed.aar` 只含 arm64 产物。

### 3.2 Release APK

```bash
flutter build apk --release --target-platform android-arm64
```

产物：`build/app/outputs/flutter-apk/app-release.apk`

当前 `1.2.8+11` 的实测产物约 26.2 MB（27,449,392 字节）。

**为什么必须带 `--target-platform android-arm64`**

`android/app/build.gradle.kts` 中已限制 ABI：

```kotlin
ndk {
    abiFilters.clear()
    abiFilters.add("arm64-v8a")
}
```

显式指定可避免 Flutter 工具链额外打包其它架构的 Flutter 引擎，减小体积、加快构建。

### 3.3 App Bundle（上架用）

```bash
flutter build appbundle --release --target-platform android-arm64
```

产物：`build/app/outputs/bundle/release/app-release.aab`

### 3.4 关键 Gradle 配置说明

```kotlin
android {
    namespace = "com.liuguang.bdmfjx"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    defaultConfig {
        applicationId = "com.liuguang.bdmfjx"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")  // 默认用调试签名
            isMinifyEnabled = false    // Go 引擎依赖反射/序列化，禁止混淆
            isShrinkResources = false
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true  // 引擎 .so 需解压到磁盘后加载
        }
    }
}

dependencies {
    implementation(files("libs/libgopeed.aar"))
}
```

| 配置 | 原因 |
| --- | --- |
| `abiFilters` 仅 `arm64-v8a` | AAR 只提供 arm64 产物 |
| `isMinifyEnabled = false` | R8 混淆会破坏 Go 引擎的反射/序列化路径 |
| `useLegacyPackaging = true` | 引擎需以传统方式解压 `.so` 到磁盘，不能用 `extractNativeLibs=false` |
| `signingConfig = debug` | 默认配置，正式发布前必须替换（见第 5 节） |

### 3.5 权限与清单

`android/app/src/main/AndroidManifest.xml` 已声明：

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"
    android:maxSdkVersion="29" />
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"
    android:maxSdkVersion="32" />
<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE" />
```

`<application>` 上的关键属性：

| 属性 | 值 | 作用 |
| --- | --- | --- |
| `android:label` | 百度公益解析 | 桌面显示名 |
| `android:usesCleartextTraffic` | `true` | 允许明文 HTTP（引擎本地回环） |
| `android:requestLegacyExternalStorage` | `true` | Android 10 兼容旧存储模型 |

`<queries>` 声明了 `com.tencent.mobileqq`、`mqqapi://`、`https://`，用于运营弹窗唤起 QQ 与打开外链。Android 11+ 不加 `<queries>` 会导致 `canLaunchUrl` 恒为 false。

---

## 4. Windows 构建

### 4.1 构建命令

```bash
flutter build windows --release
```

产物目录：`build/windows/x64/runner/Release/`

包含：

```
tierflow.exe
flutter_windows.dll
dartjni.dll
gopeed-rest.exe
data/
  app.so
  icudtl.dat
  flutter_assets/
```

### 4.2 引擎自动复制

`windows/runner/CMakeLists.txt` 末尾已配置 POST_BUILD 复制，无需手动拷贝：

```cmake
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/gopeed-rest.exe"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/gopeed-rest.exe"
  COMMENT "Copying gopeed-rest.exe engine")
```

若产物目录里没有 `gopeed-rest.exe`，说明该段被删或构建缓存异常，执行 `flutter clean` 后重建。

### 4.3 引擎文件查找顺序

运行时按以下顺序查找 `gopeed-rest.exe`（`GopeedEngine._findEngineExe`）：

1. `dirname(Platform.resolvedExecutable)/gopeed-rest.exe`
2. `Directory.current/gopeed-rest.exe`
3. `Directory.current/windows/runner/gopeed-rest.exe`
4. `Directory.current/build/windows/x64/runner/gopeed-rest.exe`

因此把 `tierflow.exe` 与 `gopeed-rest.exe` 放在同一目录即可直接运行。

### 4.4 分发打包

```powershell
# 在 build/windows/x64/runner/Release 的上一级执行
Compress-Archive -Path .\Release\* -DestinationPath .\tierflow-windows-x64.zip -Force
```

> 注意：`data/` 目录必须与 `tierflow.exe` 同级保留，只发 exe 无法运行。

### 4.5 窗口与图标

| 项 | 值 | 位置 |
| --- | --- | --- |
| 窗口标题 | `百度公益解析` | `windows/runner/main.cpp`（UTF-16 转义 `L"\u767e\u5ea6\u516c\u76ca\u89e3\u6790"`） |
| 初始尺寸 | 1280 × 720 | 同上 |
| 应用图标 | `windows/runner/resources/app_icon.ico` | 替换后需重新构建 |

---

## 5. 发布签名

仓库当前 release 使用 **debug 签名**，仅适合内部测试。正式分发必须替换。

### 5.1 生成 keystore

```bash
keytool -genkeypair -v ^
  -keystore release.jks ^
  -keyalg RSA -keysize 2048 -validity 10000 ^
  -alias baidujiexi
```

### 5.2 配置签名

在 `android/` 下新建 `key.properties`（**该文件已被 `.gitignore` 忽略**）：

```properties
storePassword=<你的密码>
keyPassword=<你的密码>
keyAlias=baidujiexi
storeFile=<keystore 绝对路径，如 D:/keys/release.jks>
```

在 `android/app/build.gradle.kts` 中加入（示例，需自行修改）：

```kotlin
import java.util.Properties
import java.io.FileInputStream

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}
```

### 5.3 校验签名

```bash
# Windows
"%JAVA_HOME%\bin\keytool" -printcert -jarfile app-release.apk

# 或使用 apksigner
"%ANDROID_HOME%\build-tools\<version>\apksigner.bat" verify --print-certs app-release.apk
```

**升级注意**：Android 要求同包名升级使用**同一签名**。更换 keystore 后老用户无法覆盖安装，必须先卸载。

---

## 6. 发版检查清单

### 6.1 版本号

修改 `pubspec.yaml`：

```yaml
version: 1.2.9+12   # versionName+versionCode
```

| 段 | 对应 | 规则 |
| --- | --- | --- |
| `1.2.9` | Android `versionName` / Windows 文件版本 | 语义化版本 |
| `12` | Android `versionCode` | **必须单调递增**，否则无法覆盖安装 |

### 6.2 发布前必做

- [ ] `flutter analyze` 无 error（warning 可接受，需评估）
- [ ] `flutter test` 全部通过
- [ ] `pubspec.yaml` 版本号已递增，`versionCode` 大于上一版
- [ ] `README.md` 的版本历史已补充
- [ ] 远程配置 `parseApiBase` 指向可用域名
- [ ] `android/app/libs/libgopeed.aar` 与 `windows/runner/gopeed-rest.exe` 均存在且完整
- [ ] release 签名已替换为正式 keystore（对外分发时）
- [ ] 真机/真环境安装验证：解析 → 选文件 → 下载 → 完成
- [ ] Android 11+ 存储权限引导流程可正常走通
- [ ] 密码查询页可正常取回密码（需真实网络与 WebView）
- [ ] 构建产物未包含 `.tmp_*`、`*.apk`、`dist/` 等无关文件

### 6.3 构建命令汇总

```bash
flutter clean
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
flutter build windows --release
```

产物：

| 平台 | 路径 |
| --- | --- |
| Android | `build/app/outputs/flutter-apk/app-release.apk` |
| Windows | `build/windows/x64/runner/Release/`（整个目录） |

---

## 7. 本机分发（可选）

以下为 Windows 本机用 phpStudy 提供下载链接的参考步骤，与项目构建本身无关。

### 7.1 目录准备

站点根目录示例：`D:\phpstudy_pro\WWW\hhh.com`

```powershell
Copy-Item "d:\TierFlow\build\app\outputs\flutter-apk\app-release.apk" `
  "D:\phpstudy_pro\WWW\hhh.com\tierflow-1.2.8-arm64.apk" -Force
```

### 7.2 本地 hosts

```
127.0.0.1 hhh.com
```

### 7.3 验证

```bash
curl.exe -sS -I http://hhh.com/tierflow-1.2.8-arm64.apk
```

期望响应：

```
HTTP/1.1 200 OK
Content-Type: application/vnd.android.package-archive
Content-Length: 27449392
Accept-Ranges: bytes
```

`Accept-Ranges: bytes` 表示支持断点续传，便于大文件下载。

### 7.4 MIME 类型

若 `Content-Type` 不是 `application/vnd.android.package-archive`，在 nginx 配置的 `mime.types` 或站点配置中补充：

```nginx
types {
    application/vnd.android.package-archive apk;
}
```

部分浏览器会因 MIME 不匹配而拒绝直接下载 APK。

---

## 8. 故障排查

### 8.1 构建类

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `SDK location not found` | 缺 `android/local.properties` | 补 `sdk.dir` 与 `flutter.sdk` |
| `./gradlew: No such file or directory` | wrapper 被 `.gitignore` 排除 | 执行 `gradle wrapper` 或 `flutter create .` |
| `cannot find symbol: com.gopeed.mobile.Mobile` | 缺 `libgopeed.aar` | 确认 `android/app/libs/libgopeed.aar` 存在 |
| `Unsupported class file major version` | JDK 版本不对 | 切换到 JDK 17 |
| `OutOfMemoryError: Java heap space` | Gradle 内存不足 | 已配置 `-Xmx8G`，仍不足则调高或关闭并行 |
| `Namespace not specified` | AGP 8+ 要求 namespace | 已在 `build.gradle.kts` 设置，检查是否被覆盖 |
| Windows 构建报找不到 C++ 工具链 | VS 未装桌面 C++ 组件 | 安装「使用 C++ 的桌面开发」工作负载 |

### 8.2 运行类

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 启动卡在引导页 | 远程配置与解析站均不可达 | 检查网络；`RemoteConfigService` 失败不阻塞，应能落到默认配置——若完全白屏，查看 `flutter run` 日志 |
| 「访问过于频繁」 | Cloudflare 429 | 等待数秒；确认 `Retry-After` 未被 CDN 剥离 |
| 弹出图形验证码 | 命中风控（`-20`） | 正常流程，输入即可 |
| 「下载引擎连接中断」 | 引擎进程死掉 | 重新发起下载会触发自愈；持续失败看引擎日志 |
| Windows 提示「未找到 gopeed-rest.exe」 | 引擎未随产物复制 | 检查 CMake POST_BUILD 段；或手动拷贝到 exe 同目录 |
| Windows 提示「Gopeed 引擎启动超时」 | 端口未就绪 / 被杀软拦截 | 检查 `GOPEED_ERROR=` 输出；将 exe 加入白名单 |
| Android 11+ 无法写入 Download | 未授予「所有文件访问」 | 进入下载页按提示跳转设置授权，或用「自定义目录」选应用可写目录 |
| 密码查询页空白 | WebView 内核过低（< 70）或站点拦截 | 升级 Android System WebView；确认 UA 为 UC |
| 密码查询页一直转圈 | Turnstile 未通过 | 点右上角「重新加载」；确认网络可访问 Cloudflare |
| 解析成功但下载 403 | 直链需要特定 UA | 确认下载时透传了 `ua` 字段 |
| 下载文件名是乱码/ID | URL 无 `outname=` | 属正常兜底，落盘名取路径末段 |

### 8.3 体积类

| 现象 | 说明 |
| --- | --- |
| APK 约 26 MB | 主要来自 `libgopeed.aar` 的 arm64 `.so`，属预期 |
| 想进一步减小 | 引擎为 Go 编译产物，压缩空间有限；不建议开启 `isMinifyEnabled`（会破坏引擎） |
| 想支持 32 位 | 需获取 armeabi-v7a 版 AAR 与对应 `.so`，修改 `abiFilters`，非当前支持范围 |

### 8.4 日志采集

**Android**

```bash
adb logcat -s flutter:V
adb logcat | findstr com.liuguang.bdmfjx
```

**Windows**

```powershell
# 手动启动引擎观察输出
.\gopeed-rest.exe --storage "$env:APPDATA\com.liuguang.bdmfjx\gopeed" --download "$env:USERPROFILE\Downloads" --max 3
```

期望首行输出 `GOPEED_PORT=<port>`；若输出 `GOPEED_ERROR=...`，按提示定位（端口占用、目录无权限等）。

**Flutter 层**

```bash
flutter run --verbose
```

`--verbose` 会打印 MethodChannel 调用与插件注册细节，适合排查 `MissingPluginException`。

---

## 附录：仓库与分支约定

| 项 | 值 |
| --- | --- |
| 远程仓库 | `https://github.com/ikooc/baidujiexi` |
| 默认分支 | `main` |
| 包名 / applicationId | `com.liuguang.bdmfjx` |
| Dart 包名 | `tierflow` |
| 应用显示名 | 百度公益解析 |
