// 基础单元测试：分享链接识别与签名工具。
//
// 对应 lib/core/models.dart 的 parseShareLink 与 lib/core/signature.dart。

import 'package:flutter_test/flutter_test.dart';

import 'package:tierflow/core/models.dart';
import 'package:tierflow/core/signature.dart';

void main() {
  group('parseShareLink', () {
    test('识别标准分享链接', () {
      final link =
          parseShareLink('https://pan.baidu.com/s/1UgeXksswnRYgvDB_aaE3Zw');
      expect(link.isValid, isTrue);
      expect(link.surl, '1UgeXksswnRYgvDB_aaE3Zw');
      expect(link.pwd, '');
    });

    test('从混合文本中提取链接与提取码', () {
      final link = parseShareLink(
        '链接：https://pan.baidu.com/s/1UgeXksswnRYgvDB_aaE3Zw 提取码：vD32',
      );
      expect(link.isValid, isTrue);
      expect(link.surl, '1UgeXksswnRYgvDB_aaE3Zw');
      expect(link.pwd, 'vD32');
    });

    test('无链接时判定为无效', () {
      expect(parseShareLink('这里没有任何网盘链接').isValid, isFalse);
    });
  });

  group('RequestSigner.sha1Hex', () {
    test('与标准 SHA-1 向量一致', () {
      expect(RequestSigner.sha1Hex('abc'), 'a9993e364706816aba3e25717850c26c9cd0d89d');
      expect(RequestSigner.sha1Hex(''), 'da39a3ee5e6b4b0d3255bfef95601890afd80709');
    });
  });
}
