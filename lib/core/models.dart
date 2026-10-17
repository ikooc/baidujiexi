/// 目标站（mf.dg22.top）数据模型：解析配置、配额、文件列表、验证码。
library;

/// 把文案里以字面量形式下发的 `\n` 统一转成真实换行。
///
/// 后台若直接填字符串（而非 JSON 转义），`\n` 会以「反斜杠 + n」两个字符下发，
/// 界面会原样显示成 `\n` 而不是换行，这里统一规整。
String normalizeLineBreaks(String raw) => raw
    .replaceAll('\\r\\n', '\n')
    .replaceAll('\\n', '\n')
    .replaceAll('\\r', '\n');

/// 站点下发的自定义按钮（`custom_button` 每行 `名称|URL`）。
class CustomButton {
  const CustomButton({required this.name, required this.url});

  final String name;
  final String url;

  /// 解析多行 `名称|URL` 文本；无法识别分隔符时整行作为名称、URL 为空。
  static List<CustomButton> parse(String raw) {
    final result = <CustomButton>[];
    for (final line in raw.split(RegExp(r'\r?\n'))) {
      final text = line.trim();
      if (text.isEmpty) continue;
      final index = text.indexOf('|');
      if (index <= 0) continue;
      final name = text.substring(0, index).trim();
      final url = text.substring(index + 1).trim();
      if (name.isEmpty || url.isEmpty) continue;
      result.add(CustomButton(name: name, url: url));
    }
    return result;
  }
}

/// `/user/parse/config` 返回的站点配置。
///
/// 默认值与前端 store 初值一致（未下发字段时回落到这些值）。
class ParseConfig {
  const ParseConfig({
    this.downloadThreads = 16,
    this.showTokenInput = true,
    this.showExtractedLinkInput = true,
    this.showAnnounce = true,
    this.announce = '',
    this.customButton = '',
    this.showHero = false,
    this.name = '',
    this.logo = '/favicon.ico',
    this.debug = false,
    this.maxOnce = 0,
    this.minSingleFilesize = 0,
    this.maxSingleFilesize = 0,
    this.maxAllFilesize = 0,
    this.allowFolder = false,
    this.needPassword = false,
    this.haveAccount = true,
  });

  /// 单文件下载线程数，前端夹取到 [1, 512]。
  final int downloadThreads;
  final bool showTokenInput;
  final bool showExtractedLinkInput;
  final bool showAnnounce;
  final String announce;
  final String customButton;
  final bool showHero;
  final String name;
  final String logo;
  final bool debug;

  /// 单次最多解析文件数（0 表示不限制）。
  final int maxOnce;

  /// 单文件最小/最大体积（字节），0 表示不限制。
  final int minSingleFilesize;
  final int maxSingleFilesize;

  /// 单次解析总体积上限（字节），0 表示不限制。
  final int maxAllFilesize;

  final bool allowFolder;
  final bool needPassword;
  final bool haveAccount;

  List<CustomButton> get buttons => CustomButton.parse(customButton);

  /// 公告为 HTML，展示前去除标签。
  String get plainAnnounce =>
      announce.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  factory ParseConfig.fromJson(Map<String, dynamic> json) {
    int intOf(String key, int fallback) =>
        (json[key] as num?)?.toInt() ?? fallback;
    bool boolOf(String key, bool fallback) {
      final value = json[key];
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) return value.toLowerCase() == 'true';
      return fallback;
    }

    final rawThreads = intOf('download_threads', 16);
    return ParseConfig(
      downloadThreads: rawThreads.clamp(1, 512),
      showTokenInput: boolOf('show_token_input', true),
      showExtractedLinkInput: boolOf('show_extracted_link_input', true),
      showAnnounce: boolOf('show_announce', true),
      announce: (json['announce'] ?? '').toString(),
      customButton: (json['custom_button'] ?? '').toString(),
      showHero: boolOf('show_hero', false),
      name: (json['name'] ?? '').toString(),
      logo: (json['logo'] ?? '/favicon.ico').toString(),
      debug: boolOf('debug', false),
      maxOnce: intOf('max_once', 0),
      minSingleFilesize: intOf('min_single_filesize', 0),
      maxSingleFilesize: intOf('max_single_filesize', 0),
      maxAllFilesize: intOf('max_all_filesize', 0),
      allowFolder: boolOf('allow_folder', false),
      needPassword: boolOf('need_password', false),
      haveAccount: boolOf('have_account', true),
    );
  }
}

/// 后台下发的启动弹窗配置（自有后端 `popup` 字段）。
///
/// 未配置或 `enabled=false` 时不弹窗；正文为空同样视为不展示。
class AppPopup {
  const AppPopup({
    this.enabled = false,
    this.title = '',
    this.content = '',
    this.actionType = 'none',
    this.actionLabel = '',
    this.actionValue = '',
    this.dismissible = true,
  });

  final bool enabled;
  final String title;
  final String content;

  /// 按钮行为：`none`（无按钮）/ `link`（打开链接）/ `qq`（复制 QQ 号）。
  final String actionType;
  final String actionLabel;
  final String actionValue;

  /// 是否允许点击遮罩或返回键关闭。
  final bool dismissible;

  /// 是否具备可展示内容（有正文或标题，且已启用）。
  bool get isVisible =>
      enabled && (content.trim().isNotEmpty || title.trim().isNotEmpty);

  /// 是否展示动作按钮（行为非 `none` 且已配置按钮文案与目标）。
  bool get hasAction =>
      actionType != 'none' &&
      actionLabel.trim().isNotEmpty &&
      actionValue.trim().isNotEmpty;

  static AppPopup fromJson(Map<String, dynamic> json) => AppPopup(
        enabled: json['enabled'] == true,
        title: (json['title'] ?? '').toString(),
        content: (json['content'] ?? '').toString(),
        actionType: (json['actionType'] ?? 'none').toString(),
        actionLabel: (json['actionLabel'] ?? '').toString(),
        actionValue: (json['actionValue'] ?? '').toString(),
        dismissible: json['dismissible'] != false,
      );
}

/// 「获取解析密码」页弹窗的内置兜底配置。
///
/// 与首页加群弹窗（`popup`）相互独立：本弹窗只说明本页怎么用、不带加群动作，
/// 后台可用 `pwdPopup` 字段整份覆盖（未下发时用这里的内置文案）。
const AppPopup kFallbackPwdPopup = AppPopup(
  enabled: true,
  title: '获取解析密码说明',
  content: '本页会自动从站点取回解析密码，全程无需手动填写。\n\n'
      '1. 在下方完成人机验证；\n'
      '2. 验证通过后会自动显示解析密码；\n'
      '3. 若验证失败或长时间没反应，点右上角「重新加载」重试。',
  dismissible: true,
);

/// `/user/parse/limit` 返回的配额信息。
class LimitInfo {
  const LimitInfo({
    this.count = 0,
    this.size = 0,
    this.expiresAt = '1970-01-01 08:00:00',
  });

  /// 剩余可解析次数。
  final int count;

  /// 剩余可解析体积（字节）。
  final int size;

  /// 配额到期时间。
  final String expiresAt;

  factory LimitInfo.fromJson(Map<String, dynamic> json) => LimitInfo(
        count: (json['count'] as num?)?.toInt() ?? 0,
        size: (json['size'] as num?)?.toInt() ?? 0,
        expiresAt: (json['expires_at'] ?? '1970-01-01 08:00:00').toString(),
      );
}

/// `get_file_list` 中的单个目录项。
class FileItem {
  const FileItem({
    required this.category,
    required this.fsId,
    required this.isDir,
    required this.size,
    required this.md5,
    required this.path,
    required this.serverFilename,
    required this.dlink,
  });

  final int category;
  final int fsId;
  final bool isDir;
  final int size;
  final String md5;
  final String path;
  final String serverFilename;
  final String dlink;

  factory FileItem.fromJson(Map<String, dynamic> json) => FileItem(
        category: (json['category'] as num?)?.toInt() ?? 0,
        fsId: (json['fs_id'] as num?)?.toInt() ?? 0,
        isDir: json['is_dir'] == true,
        size: (json['size'] as num?)?.toInt() ?? 0,
        md5: (json['md5'] ?? '').toString(),
        path: (json['path'] ?? '').toString(),
        serverFilename: (json['server_filename'] ?? '').toString(),
        dlink: (json['dlink'] ?? '').toString(),
      );
}

/// `get_file_list` 返回的分享内容：文件列表 + 后续解析所需的凭据。
class FileListData {
  const FileListData({
    required this.list,
    required this.randsk,
    required this.uk,
    required this.shareid,
  });

  final List<FileItem> list;
  final String randsk;
  final String uk;
  final String shareid;

  factory FileListData.fromJson(Map<String, dynamic> json) {
    final rawList = json['list'];
    final items = <FileItem>[];
    if (rawList is List) {
      for (final item in rawList) {
        if (item is Map<String, dynamic>) items.add(FileItem.fromJson(item));
      }
    }
    return FileListData(
      list: items,
      randsk: (json['randsk'] ?? '').toString(),
      uk: (json['uk'] ?? '').toString(),
      shareid: (json['shareid'] ?? '').toString(),
    );
  }
}

/// `get_download_links` 解析出的一条直链。
///
/// 服务端 `data` 为对象数组，每项形如
/// `{message, filename, fs_id, ua, urls: [...]}`；真实直链在 `urls` 中，
/// 且必须以 `ua` 作为 `User-Agent` 请求头才能下载。
class DirectLink {
  const DirectLink({required this.url, this.name = '', this.ua = ''});

  /// 真实下载直链。
  final String url;

  /// 服务端返回的文件名（`filename`），为空时由调用方兜底。
  final String name;

  /// 下载该直链所需的 `User-Agent`。
  final String ua;

  /// 解析 `data`：逐项展开 `urls`，继承该对象的 `filename` 与 `ua`。
  static List<DirectLink> parseList(dynamic data) {
    final result = <DirectLink>[];
    if (data is List) {
      for (final item in data) {
        if (item is! Map) continue;
        final map = item.map((k, v) => MapEntry('$k', v));
        final ua = (map['ua'] ?? '').toString();
        final name = (map['filename'] ?? '').toString();
        final urls = map['urls'];
        if (urls is! List) continue;
        for (final raw in urls) {
          final url = (raw ?? '').toString();
          if (url.isNotEmpty) {
            result.add(DirectLink(url: url, name: name, ua: ua));
          }
        }
      }
    } else if (data is String && data.isNotEmpty) {
      result.add(DirectLink(url: data));
    }
    return result;
  }
}

/// 图形验证码状态。
class VcodeInfo {
  const VcodeInfo({
    this.hitCaptcha = false,
    this.vcodeStr = '',
    this.vcodeImg = '',
    this.vcodeInput = '',
  });

  /// 是否已触发验证码流程。
  final bool hitCaptcha;
  final String vcodeStr;
  final String vcodeImg;
  final String vcodeInput;

  factory VcodeInfo.fromJson(Map<String, dynamic> json) => VcodeInfo(
        hitCaptcha: json['hit_captcha'] == true,
        vcodeStr: (json['vcode_str'] ?? '').toString(),
        vcodeImg: (json['vcode_img'] ?? '').toString(),
      );

  VcodeInfo copyWith({bool? hitCaptcha, String? vcodeStr, String? vcodeImg, String? vcodeInput}) =>
      VcodeInfo(
        hitCaptcha: hitCaptcha ?? this.hitCaptcha,
        vcodeStr: vcodeStr ?? this.vcodeStr,
        vcodeImg: vcodeImg ?? this.vcodeImg,
        vcodeInput: vcodeInput ?? this.vcodeInput,
      );
}

/// 分享链接解析结果（标准化的 url / surl / pwd）。
class ShareLink {
  const ShareLink({required this.url, required this.surl, required this.pwd});

  /// 完整分享链接（含 `?pwd=`）。
  final String url;

  /// 分享 id（`/s/1` 之后的部分）。
  final String surl;

  /// 提取码。
  final String pwd;

  bool get isValid => surl.isNotEmpty;
}

/// 从任意文本中识别百度网盘分享链接（含提取码）。
///
/// 提取码可来自链接的 `?pwd=`，也可来自 `提取码：vD32` 之类的中文描述。
ShareLink parseShareLink(String raw) {
  final text = raw.trim();
  var surl = '';
  final canonical =
      RegExp(r'https?://pan\.baidu\.com/s/([A-Za-z0-9_-]+)').firstMatch(text);
  if (canonical != null) {
    // surl 必须包含 `/s/` 之后的完整串（含首位 `1`），否则百度返回 errno -130。
    surl = canonical.group(1)!;
  } else {
    final wap = RegExp(r'https?://pan\.baidu\.com/wap/init/?\?[^\s]*?surl=([A-Za-z0-9_-]+)')
        .firstMatch(text);
    if (wap != null) surl = wap.group(1)!;
  }
  if (surl.isEmpty) {
    return ShareLink(url: text, surl: '', pwd: '');
  }

  final inUrl = RegExp(r'[?&]pwd=([^&\s]+)').firstMatch(text);
  final pwd = inUrl?.group(1) ?? _pwdFromText(text);
  final url = pwd.isEmpty
      ? 'https://pan.baidu.com/s/$surl'
      : 'https://pan.baidu.com/s/$surl?pwd=$pwd';
  return ShareLink(url: url, surl: surl, pwd: pwd);
}

String _pwdFromText(String text) {
  final match = RegExp(r'(?:提取码|访问码|密码|pwd)\s*[:：=]?\s*([A-Za-z0-9]{4})(?![A-Za-z0-9])')
      .firstMatch(text);
  return match?.group(1) ?? '';
}

/// 面向用户的业务/网络异常，[message] 可直接展示。
class ParseException implements Exception {
  const ParseException(this.message, {this.code});

  final String message;

  /// 服务端业务码（无则为 null）。
  final int? code;

  /// 服务端提示签名为「需要图形验证码」。
  bool get needCaptcha => message.contains('-20');

  @override
  String toString() => message;
}
