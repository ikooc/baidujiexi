/// 目标站（mf.dg22.top）请求签名。
///
/// 站点的 axios 请求拦截器对每个业务对象计算三个签名字段：
///  * `rand1` = SHA1(业务对象 JSON 字符串)（先于 rand1/rand2/rand3 写入前计算）
///  * `rand2` = 设备指纹（浏览器端来自 FingerprintJS 的 visitorId）
///  * `rand3` = SHA1(rand2)
///
/// 服务端只校验 `rand3 == sha1(rand2)` 且 `rand1` 与业务字段一致，
/// 因此客户端只需一个稳定的 32 位 hex 指纹即可；此处生成一次并持久化，
/// 保证同一设备每次启动得到相同 rand2（与浏览器指纹行为一致）。
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RequestSigner {
  RequestSigner._();

  static final RequestSigner instance = RequestSigner._();

  static const String _fingerprintKey = 'client_fingerprint_v1';

  String? _fingerprint;

  /// 计算并返回 SHA1 十六进制摘要（40 位小写）。
  static String sha1Hex(String input) =>
      sha1.convert(utf8.encode(input)).toString();

  /// 设备指纹（rand2）。首次调用生成并写入本地，之后固定不变。
  Future<String> fingerprint() async {
    final cached = _fingerprint;
    if (cached != null) return cached;

    final prefs = await SharedPreferences.getInstance();
    var value = prefs.getString(_fingerprintKey);
    if (value == null || value.length != 32) {
      value = _randomHex(32);
      await prefs.setString(_fingerprintKey, value);
    }
    _fingerprint = value;
    return value;
  }

  /// 对业务对象 [payload] 追加 `rand1`/`rand2`/`rand3`，返回新对象。
  ///
  /// 键顺序与前端保持一致：业务字段 → rand1 → rand2 → rand3，
  /// 因为 `rand1` 是按插入顺序序列化后的字符串计算的。
  Future<Map<String, dynamic>> sign(Map<String, dynamic> payload) async {
    final body = Map<String, dynamic>.of(payload);
    final rand1 = sha1Hex(jsonEncode(body));
    final rand2 = await fingerprint();
    body['rand1'] = rand1;
    body['rand2'] = rand2;
    body['rand3'] = sha1Hex(rand2);
    return body;
  }

  static String _randomHex(int length) {
    const chars = '0123456789abcdef';
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      buffer.write(chars[random.nextInt(chars.length)]);
    }
    return buffer.toString();
  }
}
