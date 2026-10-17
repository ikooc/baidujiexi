/// 目标站（mf.dg22.top）API 客户端。
///
/// 站点为 Vue3 SPA，前端 axios 实例配置为：
///  * `baseURL = /api/v1`
///  * `headers = {Accept: application/json, text/plain, */*, Content-Type: application/json}`
///  * 请求拦截器为每个请求的 `params`(GET) / `data`(POST) 追加签名三字段（见 [RequestSigner]）
///  * 响应拦截器直接返回 `response.data`，非 2xx 时以 `data.message` 报错
///
/// 因此这里只暴露业务语义方法，签名与错误映射统一收口在 [_send]。
///
/// [baseUrl] 默认指向内置站点，启动时会用自有后端下发的 `parseApiBase` 覆盖，
/// 换域名无需重新打包。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'signature.dart';

class ParseApiClient {
  ParseApiClient({http.Client? httpClient, this.baseUrl = defaultBaseUrl})
      : _http = httpClient ?? http.Client();

  /// 内置默认站点；远程配置未下发时回落到此。
  static const String defaultBaseUrl = 'https://mf.dg22.top/api/v1';

  static const Duration _timeout = Duration(seconds: 30);

  static const String _tokenKey = 'parse_token';

  final http.Client _http;

  /// 目标站接口地址，启动时可由远程配置覆盖。
  String baseUrl;

  String _token = 'guest';

  /// 当前解析 token（默认 `guest`，与前端 localStorage 行为一致）。
  String get token => _token;

  /// 从本地读取已保存的 token；首次使用保持 `guest`。
  Future<void> loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_tokenKey) ?? 'guest';
  }

  Future<void> setToken(String value) async {
    _token = value.trim().isEmpty ? 'guest' : value.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, _token);
  }

  /// `GET /user/parse/config` —— 站点配置。
  ///
  /// 响应结构与其余接口一致：拦截器返回的响应体为 `{code, message, data}`，
  /// 实际配置在 `data` 中（参见 index.js 的 config store `{...o.data}`）。
  Future<ParseConfig> getConfig() async {
    final body = await _send('GET', '/user/parse/config', {'token': _token});
    return ParseConfig.fromJson(_asMap(body['data']));
  }

  /// `GET /user/parse/limit` —— 剩余配额。
  Future<LimitInfo> getLimit() async {
    final body = await _send('GET', '/user/parse/limit', {'token': _token});
    return LimitInfo.fromJson(_asMap(body['data']));
  }

  /// `POST /user/parse/get_file_list` —— 拉取分享目录。
  Future<FileListData> getFileList({
    required String url,
    required String surl,
    required String pwd,
    String dir = '/',
    required String parsePassword,
  }) async {
    final body = await _send('POST', '/user/parse/get_file_list', {
      'url': url,
      'surl': surl,
      'pwd': pwd,
      'dir': dir,
      'parse_password': parsePassword,
      'token': _token,
    });
    return FileListData.fromJson(_asMap(body['data']));
  }

  /// `POST /user/parse/get_vcode` —— 获取图形验证码。
  Future<VcodeInfo> getVcode({required String parsePassword}) async {
    final body = await _send('POST', '/user/parse/get_vcode', {
      'parse_password': parsePassword,
    });
    final data = _asMap(body['data']);
    return VcodeInfo.fromJson(data).copyWith(hitCaptcha: true);
  }

  /// `POST /user/parse/get_download_links` —— 解析单个文件的下载直链。
  ///
  /// 服务端 `data` 为对象数组，每项含 `filename` / `ua` / `urls`（真实直链列表）；
  /// 这里展开为 [DirectLink] 列表，并保留 `ua` 供下载引擎透传。
  Future<List<DirectLink>> getDownloadLinks({
    required String randsk,
    required String uk,
    required String shareid,
    required List<int> fsId,
    required List<String> dlink,
    required String surl,
    required String dir,
    required String pwd,
    required String parsePassword,
    String vcodeStr = '',
    String vcodeInput = '',
  }) async {
    final body = await _send('POST', '/user/parse/get_download_links', {
      'randsk': randsk,
      'uk': uk,
      'shareid': shareid,
      'fs_id': fsId,
      'dlink': dlink,
      'surl': surl,
      'dir': dir,
      'pwd': pwd,
      'token': _token,
      'parse_password': parsePassword,
      'vcode_str': vcodeStr,
      'vcode_input': vcodeInput,
    });
    return DirectLink.parseList(body['data']);
  }

  /// 命中限流（HTTP 429）时的最大重试次数。
  static const int _maxRetry = 2;

  /// 统一发送：签名 → 请求 → 解包 → 错误映射。
  ///
  /// GET 走 query（与前端 `qs.stringify` 行为一致），POST 走 JSON body。
  /// 解析站位于 Cloudflare 后方，短时间连发会返回 HTTP 429（限流），
  /// 这里按响应头 `Retry-After` 退避后重试 [ _maxRetry ] 次。
  Future<Map<String, dynamic>> _send(
    String method,
    String path,
    Map<String, dynamic> payload,
  ) async {
    final signed = await RequestSigner.instance.sign(payload);
    final uri = Uri.parse('$baseUrl$path');

    for (var attempt = 0;; attempt++) {
      http.Response response;
      try {
        if (method == 'GET') {
          response = await _http
              .get(uri.replace(queryParameters: signed.map((k, v) => MapEntry(k, '$v'))),
                  headers: _headers)
              .timeout(_timeout);
        } else {
          response = await _http
              .post(uri, headers: _headers, body: jsonEncode(signed))
              .timeout(_timeout);
        }
      } on TimeoutException {
        throw const ParseException('请求超时，请检查网络后重试');
      } catch (error) {
        throw ParseException('网络请求失败：$error');
      }

      // 被 Cloudflare 限流：等待 Retry-After 后重试，超过次数再提示用户。
      if (response.statusCode == 429) {
        if (attempt < _maxRetry) {
          await Future<void>.delayed(_retryAfter(response));
          continue;
        }
        throw const ParseException('访问过于频繁，请等几秒后重试');
      }

      final decoded = _decode(response.body);

      if (response.statusCode >= 400) {
        throw ParseException(_messageOf(decoded) ?? '请求失败（HTTP ${response.statusCode}）',
            code: _codeOf(decoded));
      }
      if (decoded == null) {
        throw const ParseException('服务器返回了无法识别的数据');
      }
      if (decoded is String && decoded.contains('SourceGuardian')) {
        throw const ParseException('服务端缺少 SourceGuardian 组件，请稍后重试');
      }
      if (decoded is! Map<String, dynamic>) {
        throw const ParseException('服务器返回格式异常');
      }

      final code = _codeOf(decoded);
      if (code != null && code != 200) {
        throw ParseException(_messageOf(decoded) ?? '请求失败（$code）', code: code);
      }
      return decoded;
    }
  }

  /// 依据响应头 `Retry-After`（秒）计算退避时长；缺省 3 秒，上限 10 秒。
  static Duration _retryAfter(http.Response response) {
    final seconds = int.tryParse(response.headers['retry-after'] ?? '');
    return Duration(seconds: (seconds ?? 3).clamp(1, 10));
  }

  Map<String, String> get _headers => const {
        'Accept': 'application/json, text/plain, */*',
        'Content-Type': 'application/json',
      };

  static dynamic _decode(String raw) {
    if (raw.trim().isEmpty) return const <String, dynamic>{};
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.map((k, v) => MapEntry('$k', v));
    return <String, dynamic>{};
  }

  static String? _messageOf(dynamic decoded) {
    if (decoded is Map) {
      final message = decoded['message'];
      if (message != null && '$message'.isNotEmpty) return '$message';
    }
    return null;
  }

  static int? _codeOf(dynamic decoded) {
    if (decoded is Map) return (decoded['code'] as num?)?.toInt();
    return null;
  }

  void dispose() => _http.close();
}
