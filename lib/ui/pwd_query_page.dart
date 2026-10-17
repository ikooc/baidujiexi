import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../core/models.dart';
import '../theme/app_theme.dart';
import 'app_popup_dialog.dart';

/// 密码查询站地址默认值（远程配置未下发时使用）。
const String kPwdSiteUrl = 'https://mmhq.dg22.top/';

/// 站点只放行 UC 浏览器 UA，其它 UA 一律 403。
const String kUcUserAgent = 'Mozilla/5.0 (Linux; U; Android 12; zh-CN; Mi 10 '
    'Build/SKQ1.220119.001) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Version/4.0 Chrome/123.0.6312.80 UCBrowser/18.10.4.1530 Mobile Safari/537.36';

/// 站点第一层密码默认值（远程配置未下发时使用）。
const String kFirstLayerPassword = '凝视深渊';

/// JS 与 Dart 之间的通信通道名。
const String _kBridge = 'TfPwdBridge';

/// WebView 内核探测通道（对应 Android 侧 `WebViewBridge`）。
const MethodChannel _kWebViewChannel = MethodChannel('com.liuguang.bdmfjx/webview');

/// 内核主版本低于此值时改用 Hybrid Composition 渲染。
///
/// 默认渲染走 Texture Layer Hybrid Composition（渲染到 SurfaceTexture），
/// 老内核在该路径上偶发黑屏、花屏、验证码不渲染；Hybrid Composition 性能略差
/// 但不依赖 SurfaceTexture，兼容性更好。见 [AndroidWebViewWidgetCreationParams]。
const int kHybridCompositionBelowMajor = 86;

/// 内核主版本低于此值时视为过旧：站点的人机验证无法通过，直接引导升级内核。
///
/// Cloudflare Turnstile 对内核有硬要求，旧内核加载页面只会停在空白。
const int kMinWebViewMajor = 70;

/// 系统 WebView 的应用商店升级页（Chrome 内核随它一起更新）。
const String kWebViewStoreUrl =
    'https://play.google.com/store/apps/details?id=com.google.android.webview';

/// 密码查询结果：第二层密码与 UC 口令。
class PwdQueryResult {
  const PwdQueryResult({required this.pwd, required this.uc});

  /// 第二层密码（即解析密码）。
  final String pwd;

  /// 站点附带的 UC 口令（可能为空）。
  final String uc;
}

/// 站点注入脚本：用户过完人机验证后自动推进后续两步，并回传结果。
///
/// 站点是单页三步流程，三步的 DOM 从页面加载起就全部存在，
/// 靠各自容器上的内联 `style.display` 切换显隐：
///   1. `#stepTurnstile` 首屏 Turnstile 验证页
///   2. `#stepPassword`  第一层密码页（自动填入 [firstPassword] 并提交）
///   3. `#stepResult`    结果页（`#pwdValue`）
///
/// 因此必须**按步骤容器判断当前步骤**，且只在结果步读取结果：
/// 密码输入框从加载起就在 DOM 里，直接找输入框会把验证码页误判成密码页，
/// 用空 cs_token 提交密码表单；UC 口令（第二步）同理常驻 DOM，
/// 提前读取会被当成已出结果，让 App 的结果面板提前盖住验证码。
/// 判断显隐只读 `style.display`：App 注入的样式脚本把整页计算样式的
/// visibility 设为 hidden，读计算样式会全部落空。
///
/// 两步自动提交都用 sessionStorage 做了「距页面加载 1.5 秒 + 6 秒节流」，
/// 避免站点回显同一页面导致重复提交。
String _buildInjectScript(String firstPassword) => '''
(function () {
  if (window.__tfPwdTick) { window.__tfPwdTick(); return; }
  var FIRST = ${jsonEncode(firstPassword)};
  var TS_KEY = '__tfTsSubmitAt';
  var PWD_KEY = '__tfPwdSubmitAt';
  // 自动提交次数上限：站点 UI 被样式脚本剥掉后用户点不到它自己的按钮，
  // 若第一层密码已失效、或 Turnstile token 被拒（token 一次性，重试必然再失败），
  // 无上限重试只会每 6 秒把同一条报错再刷一遍。留少量重试覆盖偶发失败，
  // 之后交给页面右上角的「重新加载」。
  var TS_MAX = 2;
  var PWD_MAX = 2;
  var loadAt = Date.now();
  var tsTries = 0;
  var pwdTries = 0;
  var lastStep = '';
  var lastCf = false;

  function byId(id) { return document.getElementById(id); }

  function textOf(el) {
    if (!el) return '';
    var tag = el.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA') return '';
    // 页面元素被样式脚本设为 visibility:hidden，浏览器对这类元素的
    // innerText 取值不稳定，这里以 textContent 为准（取值与呈现无关）。
    var raw = (el.textContent || '').trim();
    if (raw) return raw;
    return (el.innerText || '').trim();
  }

  function hasClass(el, name) {
    if (!el) return false;
    if (el.classList) return el.classList.contains(name);
    return (' ' + (el.className || '') + ' ').indexOf(' ' + name + ' ') !== -1;
  }

  function readAt(key) {
    try { return parseInt(sessionStorage.getItem(key) || '0', 10) || 0; }
    catch (e) { return 0; }
  }
  function writeAt(key) {
    try { sessionStorage.setItem(key, String(Date.now())); } catch (e) {}
  }
  // 距页面加载不足 1.5 秒，或距上次同类提交不足 6 秒时，不允许自动提交。
  function blocked(key) {
    if (Date.now() - loadAt < 1500) return true;
    return (Date.now() - readAt(key)) <= 6000;
  }

  // 站点整站被 Cloudflare 全页挑战（Just a moment...）接管时，业务 DOM
  // 一个都不存在，三步判断必然落空。这里识别挑战页，交给 App 提示用户。
  function cfChallenge() {
    try {
      var title = (document.title || '').toLowerCase();
      if (title.indexOf('just a moment') !== -1) return true;
      if (title.indexOf('attention required') !== -1) return true;
      if (document.getElementById('challenge-error-text')) return true;
      if (document.querySelector('#challenge-form, #challenge-running, #challenge-stage')) {
        return true;
      }
      var body = (document.body && document.body.textContent) || '';
      if (body.indexOf('Enable JavaScript and cookies to continue') !== -1) return true;
      if (body.indexOf('Verifying you are human') !== -1) return true;
      var flat = body.replace(/\\s+/g, ' ').trim();
      if (flat.length < 400 && flat.indexOf('Access Denied') !== -1) return true;
    } catch (e) {}
    return false;
  }

  // 站点靠容器上的内联 display 切换步骤；没有内联样式即视为显示中。
  function stepShown(id) {
    var el = byId(id);
    return !!el && el.style.display !== 'none';
  }

  function currentStep() {
    if (stepShown('stepResult')) return 'result';
    if (stepShown('stepPassword')) return 'password';
    if (stepShown('stepTurnstile')) return 'turnstile';
    return 'unknown';
  }

  function findPasswordInput() {
    var el = byId('accessPwdInput');
    if (el) return el;
    var nodes = document.querySelectorAll('input');
    for (var i = 0; i < nodes.length; i++) {
      var type = (nodes[i].getAttribute('type') || '').toLowerCase();
      var name = (nodes[i].getAttribute('name') || '').toLowerCase();
      if (type === 'password' || name === 'password') return nodes[i];
    }
    return null;
  }

  // 点站点自己的提交按钮，让它 onsubmit 里的 fetch 链路原样跑起来；
  // 按钮缺失时才退回直接提交表单。
  function clickSubmit(id, fallbackSelector, key) {
    var btn = byId(id);
    if (!btn) btn = document.querySelector(fallbackSelector);
    if (!btn) return;
    writeAt(key);
    if (typeof btn.click === 'function') { btn.click(); return; }
    var form = btn.form || (btn.closest ? btn.closest('form') : null);
    if (!form) return;
    if (typeof form.requestSubmit === 'function') form.requestSubmit(btn);
    else form.submit();
  }

  function advance() {
    var step = currentStep();
    // 步骤变化时清零计数：站点重新回到验证码页（如 token 失效后 reload）
    // 属于新一轮流程，应当允许再次自动提交。
    if (step !== lastStep) {
      lastStep = step;
      if (step === 'turnstile') tsTries = 0;
      if (step === 'password') pwdTries = 0;
    }
    if (step === 'turnstile') {
      if (tsTries >= TS_MAX) return;
      // Turnstile 通过后会把响应写进隐藏字段，据此判断可以点「下一步」。
      var token = document.querySelector('[name="cf-turnstile-response"]');
      if (!token || !token.value) return;
      if (blocked(TS_KEY)) return;
      tsTries++;
      clickSubmit('btnTurnstileNext', 'button[type=submit], input[type=submit]', TS_KEY);
      return;
    }
    if (step === 'password') {
      if (pwdTries >= PWD_MAX) return;
      var input = findPasswordInput();
      if (!input) return;
      if (input.value !== FIRST) {
        input.value = FIRST;
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
      }
      if (blocked(PWD_KEY)) return;
      pwdTries++;
      clickSubmit('btnSubmitPwd', 'button[type=submit], input[type=submit]', PWD_KEY);
    }
  }

  // 站点结果页现在只渲染掩码（如 ••••••••••），明文仅存在页面全局变量里：
  //   服务端下发加密 payload，页面用 WebCrypto 在本地解密后写入 currentParsePwd，
  //   密码框只为「复制按钮」服务。读 DOM 文本只会拿到圆点，必须读变量。
  //
  // 注意：站点的密钥派生参与环境签名（校验 Function.prototype.toString、
  // crypto.subtle.* 是否为原生实现），因此这里绝不能 hook 任何 WebCrypto
  // 方法，否则解密会静默失败。
  function isMask(s) {
    if (!s) return true;
    // 圆点（U+2022）、间隔点、实心/空心圆、星号、日文中点。
    return !/[^\\u2022\\u00b7\\u2027\\u25cf\\u25cb\\u002a\\uff65\\u30fb\\s]/.test(s);
  }

  // 读取站点解密后的明文密码。var 与 let 顶格声明都会成为全局绑定，
  // let 不挂在 window 上，所以先用裸标识符探测，再退回 window 属性。
  function sitePwd() {
    try {
      if (typeof currentParsePwd === 'string') return currentParsePwd.trim();
    } catch (e) {}
    try {
      if (typeof window.currentParsePwd === 'string') {
        return window.currentParsePwd.trim();
      }
    } catch (e) {}
    return '';
  }

  // 取解析密码：优先取页面变量里的明文；变量还没写入时（解密中）
  // 退回 DOM，但掩码圆点不算密码，避免把「••••」当成结果回传。
  function pickPwd() {
    var decoded = sitePwd();
    if (decoded && !isMask(decoded)) return decoded;
    var el = byId('pwdValue') || document.querySelector('.pwd-box .pwd');
    if (!el || hasClass(el, 'empty')) return '';
    var txt = textOf(el);
    if (isMask(txt)) return '';
    return txt;
  }

  // 取结果页的「无密码」提示（同一个元素的 empty 形态）。
  function pickNotice() {
    var el = byId('pwdValue') || document.querySelector('.pwd-box .empty');
    if (!el || !hasClass(el, 'empty')) return '';
    return textOf(el);
  }

  // 取 UC 口令：站点第二层（密码页）放在 .uc-box 内（id="ucText"）。
  function pickUc() {
    var el = byId('ucText') || document.querySelector('.uc-box .uc-text');
    return textOf(el);
  }

  window.__tfPwdTick = function () {
    advance();
    // 全页挑战期间业务 DOM 不存在，只回传挑战标记，避免 App 一直空等。
    var cf = cfChallenge();
    // 只有走到结果步才读结果：三步 DOM 同时存在，提前读会把隐藏步骤里的
    // 内容当成已出结果。错误提示不受此限，验证码页失败也要能回传。
    var pwd = '';
    var uc = '';
    var note = '';
    if (currentStep() === 'result') {
      pwd = pickPwd();
      uc = pickUc();
      note = pickNotice();
    }
    // 站点错误框 `#pwdErrorBox` 默认内联 display:none，只有真的报错才 display:block。
    var errEl = byId('pwdErrorBox') || document.querySelector('.error');
    var err = errEl && errEl.style.display !== 'none' ? textOf(errEl) : '';
    if (!pwd && !uc && !note && !err && cf === lastCf) return;
    lastCf = cf;
    try {
      $_kBridge.postMessage(JSON.stringify({
        pwd: pwd, uc: uc, notice: note, error: err, cf: cf
      }));
    } catch (e) {}
  };
  window.__tfPwdTick();
  if (!window.__tfPwdTimer) {
    window.__tfPwdTimer = setInterval(window.__tfPwdTick, 800);
  }
})();
''';

/// 站点样式剥离脚本：只保留 Turnstile 验证码，隐藏站点自身的页面外观。
///
/// 站点是「验证码 → 密码 → 结果」整页跳转，三种页面都套着同样的 `.card`
/// 外壳（标题、按钮、输入框、结果框）。这里用 `visibility` 把整页元素藏起来，
/// 再单独放行 `.turnstile-wrap` 子树，于是用户只看到验证码控件，
/// 密码与结果一律由 App 自己的原生界面呈现。
///
/// `visibility: hidden` 只让元素不可见、仍占布局，站点的标题、提示框、按钮
/// 会把验证码顶到大片空白之下；因此对站点自己的壳层元素再补 `display: none`
/// 直接移出布局。站点容器 `#stepPassword` / `#stepResult` 被强制隐藏后，
/// [ _buildInjectScript ] 仍可读它们的内联 `style.display` 判断步骤 —— CSS
/// 不改变内联样式值。
String _buildStyleScript() => '''
(function () {
  var ID = '__tfPwdStyle';
  if (document.getElementById(ID)) return;
  // Cloudflare 全页挑战（Just a moment...）不是站点业务页：隐藏任何元素都会
  // 让挑战控件不可见、用户无法完成校验，因此整页原样放行。
  var t = (document.title || '').toLowerCase();
  if (t.indexOf('just a moment') !== -1 || t.indexOf('attention required') !== -1) return;
  if (document.getElementById('challenge-error-text') ||
      document.querySelector('#challenge-form, #challenge-running, #challenge-stage')) return;
  var css = [
    'html, body { background: transparent !important; }',
    '.card { background: transparent !important; box-shadow: none !important;',
    '  border-radius: 0 !important; padding: 0 !important; margin: 0 !important;',
    '  max-width: 100% !important; }',
    'body * { visibility: hidden !important; }',
    '.turnstile-wrap, .turnstile-wrap *, .cf-turnstile, .cf-turnstile *',
    '  { visibility: visible !important; }',
    // 站点壳层移出布局：标题、黄色提示框（引导去 mf.dg22.top）、UC 口令框、
    // 提交按钮、错误框、密码与结果两步。App 用原生界面承担这些内容。
    '#stepTurnstile > h2, .notice, .uc-box, #pwdErrorBox,',
    '#btnTurnstileNext, .uc-copy, #stepPassword, #stepResult,',
    '.pwd-box, .meta, #copyBtn { display: none !important; }'
  ].join('\\n');
  var style = document.createElement('style');
  style.id = ID;
  style.type = 'text/css';
  style.appendChild(document.createTextNode(css));
  (document.head || document.documentElement).appendChild(style);
})();
''';

/// 密码查询页：内嵌 WebView 打开站点，用户手动完成人机验证，
/// App 自动回填第一层密码并抓取第二层密码与 UC 口令。
///
/// 站点首屏是 Cloudflare Turnstile，纯 HTTP 客户端无法通过，必须走真实浏览器。
/// 站点地址与第一层密码支持由自有后端远程下发（见 [RemoteAppConfig]）。
///
/// 界面只呈现验证码：站点原页面被 [ _buildStyleScript ] 剥离，
/// 拿到密码后连 WebView 一起隐藏，改为 App 原生结果卡片。
class PwdQueryPage extends StatefulWidget {
  const PwdQueryPage({
    super.key,
    this.siteUrl = kPwdSiteUrl,
    this.firstPassword = kFirstLayerPassword,
    this.popup = kFallbackPwdPopup,
    this.onPasswordCaptured,
  });

  /// 密码查询站地址，来自远程配置 `pwdSiteUrl`。
  final String siteUrl;

  /// 站点第一层密码，来自远程配置 `pwdFirstPassword`。
  final String firstPassword;

  /// 本页专用弹窗说明，来自远程配置 `pwdPopup`（未下发时用 [kFallbackPwdPopup]）。
  ///
  /// 与首页加群弹窗相互独立，未启用时不弹。
  final AppPopup popup;

  /// 抓到解析密码时的回调：调用方据此立即生效，无需用户再点按钮。
  ///
  /// 这样即使用户直接用系统返回键退出本页，密码也已经写入并可用。
  final ValueChanged<PwdQueryResult>? onPasswordCaptured;

  /// WebView 仅支持 Android / iOS / macOS，其它平台无法使用本页。
  static bool get isSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  @override
  State<PwdQueryPage> createState() => _PwdQueryPageState();
}

class _PwdQueryPageState extends State<PwdQueryPage> {
  late final WebViewController _controller;

  bool _loading = true;
  String _pwd = '';
  String _uc = '';
  String? _error;

  /// 站点回显的错误文案（如「人机验证失败，请重试」）。
  String _siteError = '';

  /// 结果页的「无密码」提示（如「暂无可用密码」），此时不算获取成功。
  String _notice = '';

  /// 当前页面是 Cloudflare 全页挑战（整站被拦截），不是站点业务页。
  bool _cf = false;

  /// 本页的弹窗公告是否已展示过（进入本页只弹一次）。
  bool _popupShown = false;

  /// 样式剥离脚本是否已在当前页面生效。
  ///
  /// 未生效前 WebView 里是站点原页面（含黄色提示框等原文案），必须用不透明
  /// 遮罩盖住，否则用户会先看到这些文案，注入完成后才消失。
  bool _styled = false;

  /// 探测到的 WebView 内核主版本号；null 表示未知（非 Android / 定制 ROM 探测失败）。
  int? _webViewMajor;

  /// 内核探测是否已结束：结束前不创建 WebView，避免先按错误方式合成一帧。
  bool _probeDone = false;

  /// 内核过旧：站点人机验证必然失败，不加载站点，改展示升级引导。
  bool get _kernelTooOld =>
      _webViewMajor != null && _webViewMajor! < kMinWebViewMajor;

  /// 老内核在默认合成方式下会黑屏 / 花屏，改用 Hybrid Composition 兜底。
  bool get _useHybridComposition =>
      defaultTargetPlatform == TargetPlatform.android &&
      _webViewMajor != null &&
      _webViewMajor! < kHybridCompositionBelowMajor;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(kUcUserAgent)
      ..addJavaScriptChannel(
        _kBridge,
        onMessageReceived: _onBridgeMessage,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _loading = true;
              // 新页面尚未注入样式，重新盖上遮罩。
              _styled = false;
              // 新页面可能已不是挑战页，先清掉提示，由注入脚本重新判定。
              _cf = false;
            });
          },
          onPageFinished: (_) async {
            // 先注入样式脚本再撤下加载遮罩：站点壳层（标题、黄色提示框）是
            // 页面自带内容，注入若晚于遮罩撤下的一瞬，用户就会先看到原文案。
            await _inject();
            if (!mounted) return;
            setState(() {
              _loading = false;
              // 兜底：注入失败也要撤下遮罩，否则验证码永远被盖住。
              _styled = true;
            });
          },
          onWebResourceError: (error) {
            // 子资源（图片等）失败不打断主流程，仅记录主文档错误。
            if (error.isForMainFrame != true) return;
            if (mounted) {
              setState(() => _error = '页面加载失败：${error.description}');
            }
          },
        ),
      );
    // 先探测内核再决定是否加载站点：内核过旧时加载也过不了人机验证。
    _probeAndLoad();
    // 首帧渲染完成后再弹公告，避免在 build 期间调用 showDialog。
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowPopup());
  }

  /// 允许第三方 Cookie。
  ///
  /// Cloudflare 的挑战在 iframe 里下发 `cf_clearance`，Android WebView 对
  /// targetSdk >= 21 默认拒绝第三方 Cookie，不开启会导致挑战永远过不去。
  Future<void> _enableThirdPartyCookies() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final platform = _controller.platform;
      final cookiePlatform = WebViewCookieManager().platform;
      if (platform is AndroidWebViewController &&
          cookiePlatform is AndroidWebViewCookieManager) {
        await cookiePlatform.setAcceptThirdPartyCookies(platform, true);
      }
    } catch (_) {
      // 老版本插件不支持时忽略，挑战仍可能通过。
    }
  }

  /// 按实际内核版本生成 UA。
  ///
  /// Cloudflare 会比对 UA 声明的 Chrome 版本与页面里的内核指纹，声明的版本
  /// 和真实内核差太多会被判为伪造。拿不到内核版本时沿用默认 UA。
  String _userAgentFor(int? major) {
    if (major == null) return kUcUserAgent;
    return kUcUserAgent.replaceFirst(
      'Chrome/123.0.6312.80',
      'Chrome/$major.0.0.0',
    );
  }

  /// 探测内核版本，并据此决定加载站点还是展示升级引导。
  Future<void> _probeAndLoad() async {
    final major = await _probeWebViewMajor();
    if (!mounted) return;
    setState(() {
      _webViewMajor = major;
      _probeDone = true;
    });
    if (_kernelTooOld) return;
    // 加载前先备好 UA 与第三方 Cookie：Cloudflare 挑战靠这两项才能过。
    await _controller.setUserAgent(_userAgentFor(major));
    await _enableThirdPartyCookies();
    await _controller.loadRequest(Uri.parse(widget.siteUrl));
  }

  /// 读取 Android 系统 WebView 的内核主版本号。
  ///
  /// 非 Android 平台（iOS / macOS）以及定制 ROM 探测失败时返回 null，
  /// 调用方按「版本未知」处理：不降级、不拦截，保持默认行为。
  Future<int?> _probeWebViewMajor() async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      return await _kWebViewChannel.invokeMethod<int>('getWebViewMajor');
    } catch (_) {
      return null;
    }
  }

  /// 展示后台下发的弹窗公告（每次进入本页最多弹一次）。
  Future<void> _maybeShowPopup() async {
    final popup = widget.popup;
    if (_popupShown || !popup.isVisible || !mounted) return;
    _popupShown = true;
    await showAppPopupDialog(context, popup: popup);
  }

  /// 把样式剥离脚本与注入脚本写入当前页面（每次页面切换后都要重新注入）。
  Future<void> _inject() async {
    try {
      await _controller.runJavaScript(_buildStyleScript());
      _markStyled();
      await _controller.runJavaScript(
        _buildInjectScript(widget.firstPassword),
      );
    } catch (_) {
      // 页面尚未就绪时忽略，下一次 onPageFinished 会重试。
    }
  }

  /// 标记样式脚本已生效，撤下遮罩。
  void _markStyled() {
    if (_styled || !mounted) return;
    setState(() => _styled = true);
  }

  /// 接收注入脚本回传的密码信息。
  void _onBridgeMessage(JavaScriptMessage message) {
    final raw = message.message;
    if (raw.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final pwd = (decoded['pwd'] ?? '').toString().trim();
    final uc = (decoded['uc'] ?? '').toString().trim();
    final notice = (decoded['notice'] ?? '').toString().trim();
    final siteError = (decoded['error'] ?? '').toString().trim();
    final cf = decoded['cf'] == true;
    if (pwd == _pwd &&
        uc == _uc &&
        notice == _notice &&
        siteError == _siteError &&
        cf == _cf) {
      return;
    }
    if (!mounted) return;
    final firstTime = pwd.isNotEmpty && pwd != _pwd;
    setState(() {
      _pwd = pwd;
      _uc = uc;
      _notice = notice;
      _siteError = siteError;
      _cf = cf;
    });
    // 首次拿到密码时立刻回调，使其在用户点「使用」或直接返回前就已生效。
    if (firstTime) {
      widget.onPasswordCaptured?.call(PwdQueryResult(pwd: pwd, uc: uc));
    }
  }

  Future<void> _copy(String value, String label) async {
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('已复制$label')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 只有真的拿到解析密码才算成功；仅拿到 UC 口令 / 无密码提示都不算。
    final hasPwd = _pwd.isNotEmpty;
    final hasPanel = hasPwd || _uc.isNotEmpty || _notice.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('获取解析密码'),
        actions: <Widget>[
          IconButton(
            tooltip: '重新加载',
            onPressed: () {
              setState(() {
                _error = null;
                _pwd = '';
                _uc = '';
                _notice = '';
                _siteError = '';
                _styled = false;
              });
              _controller.loadRequest(Uri.parse(widget.siteUrl));
            },
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _buildHint(theme),
            if (_loading && !hasPanel)
              const LinearProgressIndicator(minHeight: 2),
            if (_error != null) _buildBanner(theme, _error!, AppColors.warning),
            if (_cf && !hasPanel) _buildCfBanner(theme),
            if (_siteError.isNotEmpty)
              _buildBanner(theme, _siteError, AppColors.danger),
            // 内核过旧时站点人机验证必然失败，不加载站点，直接引导升级。
            if (_kernelTooOld)
              Expanded(child: _buildKernelTooOldPanel(theme))
            // 探测未回来前不创建平台视图，避免先按错误方式合成一帧。
            else if (!_probeDone)
              const Expanded(
                child: Center(child: CircularProgressIndicator()),
              )
            else
              // 拿到结果后用不透明面板整体盖住 WebView：既彻底遮掉站点原页面，
              // 又保持 WebView 存活，避免销毁平台视图导致桥接通道中断。
              Expanded(
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(child: _buildWebView()),
                    if (hasPanel)
                      Positioned.fill(
                        child: ColoredBox(
                          color: AppColors.background,
                          child: hasPwd
                              ? _buildSuccessPanel(theme)
                              : _buildNoPwdPanel(theme),
                        ),
                      )
                    // 样式脚本生效前 WebView 里是站点原页面（标题、黄色提示框
                    // 等原文案都会露出），用不透明遮罩盖住，等注入完成再撤下。
                    else if (!_styled)
                      Positioned.fill(
                        child: ColoredBox(
                          color: AppColors.background,
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                const CircularProgressIndicator(),
                                const SizedBox(height: 14),
                                Text(
                                  '正在准备验证页面…',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 构建内嵌 WebView，老内核降级为 Hybrid Composition 渲染。
  ///
  /// 默认走 Texture Layer Hybrid Composition（渲染到 SurfaceTexture），
  /// 部分老机型 / 老内核在该路径下黑屏或验证码不渲染；
  /// [AndroidWebViewWidgetCreationParams.displayWithHybridComposition] 换成传统
  /// Hybrid Composition，牺牲一点性能换兼容性。非 Android 平台保持原样。
  Widget _buildWebView() {
    if (!_useHybridComposition) {
      return WebViewWidget(controller: _controller);
    }
    return WebViewWidget.fromPlatformCreationParams(
      params: AndroidWebViewWidgetCreationParams(
        controller: _controller.platform,
        displayWithHybridComposition: true,
      ),
    );
  }

  /// 内核过旧时的升级引导：站点人机验证对内核版本有硬要求，只能升级内核。
  Widget _buildKernelTooOldPanel(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(Icons.system_update_rounded, size: 56, color: AppColors.warning),
          const SizedBox(height: 14),
          Text(
            '系统 WebView 内核过旧',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          Text(
            '当前内核版本 Chrome/$_webViewMajor，站点的人机验证组件要求更高版本，'
            '继续打开只会停留在空白页。\n\n'
            '请到应用商店升级「Android System WebView」，或把系统更新到最新版本后再试。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 26),
          SizedBox(
            height: 50,
            child: FilledButton.icon(
              onPressed: () => _openStore(),
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('去应用商店升级'),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 50,
            child: OutlinedButton.icon(
              onPressed: _probeAndLoad,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('我已升级，重新检测'),
            ),
          ),
        ],
      ),
    );
  }

  /// 跳转应用商店的 WebView 升级页；无商店时复制包名兜底。
  Future<void> _openStore() async {
    final uri = Uri.tryParse(kWebViewStoreUrl);
    if (uri != null) {
      try {
        final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (ok) return;
      } catch (_) {
        // 落到下方复制兜底。
      }
    }
    await Clipboard.setData(
      const ClipboardData(text: 'com.google.android.webview'),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('已复制包名 com.google.android.webview')),
      );
  }

  /// 拿到结果后的原生展示：只呈现解析密码与「使用该密码」。
  Widget _buildSuccessPanel(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(Icons.verified_rounded, size: 56, color: AppColors.success),
          const SizedBox(height: 14),
          Text(
            '验证通过，已获取解析密码',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 24),
          if (_pwd.isNotEmpty)
            _buildValueRow(
              theme,
              label: '解析密码',
              value: _pwd,
              highlight: true,
            ),
          const SizedBox(height: 28),
          SizedBox(
            height: 50,
            child: FilledButton.icon(
              onPressed: _pwd.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(
                        PwdQueryResult(pwd: _pwd, uc: _uc),
                      ),
              icon: const Icon(Icons.check_circle_outline_rounded),
              label: const Text('使用该密码'),
            ),
          ),
        ],
      ),
    );
  }

  /// 站点点名「没有可用密码」时的展示。
  Widget _buildNoPwdPanel(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(Icons.error_outline_rounded, size: 56, color: AppColors.warning),
          const SizedBox(height: 14),
          Text(
            _notice.isNotEmpty ? _notice : '未获取到解析密码',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            '站点本次没有下发解析密码，可点击右上角重新加载重试。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          // 站点仍需时间下发密码时，给出「正在等待」的加载提示：
          // 注入脚本每 800ms 轮询一次，期间一旦拿到密码会自动切换到结果面板。
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text(
                '正在等待站点下发解析密码，请稍候…',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          SizedBox(
            height: 50,
            child: OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  _error = null;
                  _pwd = '';
                  _uc = '';
                  _notice = '';
                  _siteError = '';
                  _styled = false;
                });
                _controller.loadRequest(Uri.parse(widget.siteUrl));
              },
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新获取'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHint(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      color: AppColors.primarySoft,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.info_outline_rounded, size: 17, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '请在下方完成人机验证，通过后会直接显示解析密码。'
              '若验证失败，可点击右上角重新加载重试。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Cloudflare 全页挑战提示：站点整站被拦，App 只能提示并给出浏览器入口。
  Widget _buildCfBanner(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      color: AppColors.warning.withValues(alpha: 0.12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Text(
              '站点正在做人机校验或被临时拦截。可先等待或点右上角刷新；'
              '若一直停在此页，请用浏览器打开完成校验，或挂代理后重试。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.warning,
                height: 1.4,
              ),
            ),
          ),
          TextButton(
            onPressed: _openSiteInBrowser,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('用浏览器打开'),
          ),
        ],
      ),
    );
  }

  /// 用外部浏览器打开密码站，交给浏览器自己过 Cloudflare 挑战。
  Future<void> _openSiteInBrowser() async {
    final uri = Uri.tryParse(widget.siteUrl);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('无法打开浏览器')));
    }
  }

  Widget _buildBanner(ThemeData theme, String message, Color color) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      color: color.withValues(alpha: 0.12),
      child: Text(
        message,
        style: theme.textTheme.bodySmall?.copyWith(color: color),
      ),
    );
  }

  Widget _buildValueRow(
    ThemeData theme, {
    required String label,
    required String value,
    bool highlight = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            '$label：',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              color: highlight ? AppColors.success : AppColors.textPrimary,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        IconButton(
          tooltip: '复制$label',
          visualDensity: VisualDensity.compact,
          onPressed: () => _copy(value, label),
          icon: const Icon(Icons.copy_rounded, size: 18),
        ),
      ],
    );
  }
}
