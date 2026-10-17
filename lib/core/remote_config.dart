/// 自有后端（ai.yodlx.com）下发配置。
///
/// 客户端启动时从这里读取目标站接口域名、公告、解析密码与启动弹窗，
/// 运营方改配置即可生效，无需重新打包。接口返回 `{code, data: {...}}`，
/// 实际字段在 `data` 中。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// 自有后端配置接口地址（公开只读）。
const String kRemoteConfigUrl = 'https://ai.yodlx.com/api/app2/config.php';

/// 拉取失败或字段缺失时的兜底公告。
const String kFallbackAnnounce = '本站免费提供解析服务，请勿用于商业用途。\n'
    '解析与下载速度受网盘限制，如失败请稍后重试。';

/// 自有后端下发的运行时配置。
class RemoteAppConfig {
  const RemoteAppConfig({
    this.parseApiBase = '',
    this.announcement = '',
    this.parsePassword = '',
    this.pwdSiteUrl = '',
    this.pwdFirstPassword = '',
    this.popup = const AppPopup(),
    this.pwdPopup = kFallbackPwdPopup,
  });

  /// 目标站（解析接口）域名，空则由调用方回落到内置默认值。
  final String parseApiBase;

  /// 首页公告文案（空则隐藏）。
  final String announcement;

  /// 站点要求的解析密码，用户无需手动填写。
  final String parsePassword;

  /// 密码查询站地址，空则由调用方回落到内置默认值。
  final String pwdSiteUrl;

  /// 密码查询站第一层密码，空则由调用方回落到内置默认值。
  final String pwdFirstPassword;

  /// 启动弹窗配置（首页加群弹窗）。
  final AppPopup popup;

  /// 「获取解析密码」页专用弹窗配置，与 [popup] 相互独立。
  final AppPopup pwdPopup;

  factory RemoteAppConfig.fromJson(Map<String, dynamic> json) {
    final rawPopup = json['popup'];
    final rawPwdPopup = json['pwdPopup'];
    return RemoteAppConfig(
      parseApiBase: (json['parseApiBase'] ?? '').toString().trim(),
      announcement: (json['announcement'] ?? '').toString().trim(),
      parsePassword: (json['parsePassword'] ?? '').toString().trim(),
      pwdSiteUrl: (json['pwdSiteUrl'] ?? '').toString().trim(),
      pwdFirstPassword: (json['pwdFirstPassword'] ?? '').toString().trim(),
      popup: rawPopup is Map
          ? AppPopup.fromJson(rawPopup.map((k, v) => MapEntry('$k', v)))
          : const AppPopup(),
      pwdPopup: rawPwdPopup is Map
          ? AppPopup.fromJson(rawPwdPopup.map((k, v) => MapEntry('$k', v)))
          : kFallbackPwdPopup,
    );
  }
}

/// 从自有后端拉取 [RemoteAppConfig]，失败返回 null 由调用方兜底。
class RemoteConfigService {
  RemoteConfigService({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  static const Duration _timeout = Duration(seconds: 8);

  /// 进程内最近一次成功拉取的配置，避免启动引导与首页重复请求。
  static RemoteAppConfig? _cached;

  /// 最近一次成功拉取的配置（未拉取或失败时为 null）。
  static RemoteAppConfig? get cached => _cached;

  /// 拉取配置；[useCache] 为 true 时命中进程内缓存直接返回。
  Future<RemoteAppConfig?> load({
    String url = kRemoteConfigUrl,
    bool useCache = true,
  }) async {
    if (useCache && _cached != null) return _cached;
    try {
      final response =
          await _http.get(Uri.parse(url)).timeout(_timeout);
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) return null;
      final data = decoded['data'];
      final payload = data is Map ? data : decoded;
      final config = RemoteAppConfig.fromJson(
          payload.map((k, v) => MapEntry('$k', v)));
      _cached = config;
      return config;
    } catch (_) {
      return null;
    }
  }
}
