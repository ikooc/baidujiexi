package com.liuguang.bdmfjx

import android.content.Context
import android.webkit.WebSettings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * WebView 内核版本探测桥。
 *
 * webview_flutter_android 只透出 WebViewFeature.isFeatureSupported，
 * 拿不到「当前 WebView 内核是什么版本」，而密码站的人机验证对内核版本有硬要求，
 * 因此这里补一个通道，由 Dart 侧据此决定是否降级渲染 / 引导升级。
 *
 * 版本取自默认 UA 里的 `Chrome/<major>.` 段 —— 内核版本号与 UA 中的 Chrome 版本一致。
 * 不引入 androidx.webkit 是因为 app 模块编译不到该库：它只在
 * webview_flutter_android 模块自己的 classpath 上。
 *
 * 读取会连带触发 WebView 内核加载，故必须留在主线程（内核内部会创建 Handler，
 * 放到子线程会抛 Looper 相关异常）；这笔开销本来在创建 WebView 时也要付，
 * Dart 侧探测期间展示 loading，用户不会看到空白。
 *
 * 定制 ROM（无 GMS、内核被重度修改）可能取不到，此时返回 null，
 * Dart 侧按「版本未知」处理：既不降级、也不拦截，保持默认行为。
 */
object WebViewBridge {
    private const val CHANNEL = "com.liuguang.bdmfjx/webview"
    private val CHROME_UA = Regex("Chrome/(\\d+)\\.")

    fun register(engine: FlutterEngine, context: Context) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getWebViewMajor" -> result.success(readMajor(context))
                    else -> result.notImplemented()
                }
            }
    }

    /** 返回内核主版本号；取不到时返回 null。 */
    private fun readMajor(context: Context): Int? = try {
        CHROME_UA.find(WebSettings.getDefaultUserAgent(context))
            ?.groupValues?.get(1)?.toIntOrNull()
    } catch (_: Throwable) {
        null
    }
}
