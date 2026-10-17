import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/models.dart';
import '../theme/app_theme.dart';

/// 展示后台下发的弹窗公告（首页启动弹窗与密码页公告共用同一套外观）。
///
/// 正文统一走 [normalizeLineBreaks]，多行文案按真实换行渲染。
/// 点击动作按钮时按 [AppPopup.actionType] 处理：`link` 打开外链、
/// `qq` 拉起手机 QQ 加群；设备无法处理该链接时回退为复制。
Future<void> showAppPopupDialog(
  BuildContext context, {
  required AppPopup popup,
  String fallbackTitle = '公告',
}) {
  final title = normalizeLineBreaks(popup.title).trim();
  final content = normalizeLineBreaks(popup.content).trim();
  // 既无「我知道了」也无动作按钮时用户会被困住，这里强制给出关闭入口。
  final canDismiss = popup.dismissible || !popup.hasAction;
  return showDialog<void>(
    context: context,
    barrierDismissible: canDismiss,
    builder: (dialogContext) => PopScope(
      canPop: canDismiss,
      child: _AppPopupDialog(
        title: title.isEmpty ? fallbackTitle : title,
        content: content,
        popup: popup,
        canDismiss: canDismiss,
      ),
    ),
  );
}

class _AppPopupDialog extends StatelessWidget {
  const _AppPopupDialog({
    required this.title,
    required this.content,
    required this.popup,
    required this.canDismiss,
  });

  final String title;
  final String content;
  final AppPopup popup;
  final bool canDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.of(context).size.height * 0.78;
    final showAction = popup.hasAction;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 26, vertical: 24),
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: AppColors.border),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 420, maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 12, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.primarySoft,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.campaign_rounded,
                        size: 20, color: AppColors.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(title, style: theme.textTheme.titleLarge),
                    ),
                  ),
                  if (canDismiss)
                    IconButton(
                      tooltip: '关闭',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded, size: 20),
                    ),
                ],
              ),
            ),
            if (content.isNotEmpty) ...<Widget>[
              const SizedBox(height: 14),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    content,
                    softWrap: true,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppColors.textSecondary,
                      height: 1.65,
                    ),
                  ),
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
              child: Row(
                children: <Widget>[
                  if (canDismiss)
                    Expanded(
                      child: SizedBox(
                        height: 48,
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('我知道了'),
                        ),
                      ),
                    ),
                  if (canDismiss && showAction) const SizedBox(width: 12),
                  if (showAction)
                    Expanded(
                      child: SizedBox(
                        height: 48,
                        child: FilledButton(
                          onPressed: () {
                            // 弹窗关闭后 context 会失效，先取出 messenger 再 pop。
                            final messenger = ScaffoldMessenger.of(context);
                            Navigator.of(context).pop();
                            unawaited(_runAction(popup, messenger));
                          },
                          child: Text(popup.actionLabel.trim()),
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
}

/// 执行弹窗动作：`link` 打开外链、`qq` 拉起 QQ 加群、其它不处理。
///
/// `qq` 的 [AppPopup.actionValue] 既支持完整的 `mqqapi://` 加群链接，
/// 也支持纯 QQ 号（自动拼成加群 deeplink）。
Future<void> _runAction(AppPopup popup, ScaffoldMessengerState messenger) async {
  final value = normalizeLineBreaks(popup.actionValue).trim();
  if (value.isEmpty) return;
  switch (popup.actionType) {
    case 'link':
      await _openUrl(value, copyOnFail: value, messenger: messenger);
    case 'qq':
      final link = value.contains('://') ? value : _qqGroupUrl(value);
      await _openUrl(link, copyOnFail: value, messenger: messenger);
    default:
      break;
  }
}

/// 由 QQ 号拼出手机 QQ 加群 deeplink（`uin` 为群号）。
String _qqGroupUrl(String group) => 'mqqapi://card/show_pslcard'
    '?src_type=internal&version=1&uin=$group&card_type=group&source=qrcode';

/// 打开外部链接；设备无法处理该链接时回退为复制，避免点击无响应。
Future<void> _openUrl(
  String url, {
  required String copyOnFail,
  ScaffoldMessengerState? messenger,
}) async {
  final uri = Uri.tryParse(url);
  if (uri != null) {
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (ok) return;
    } catch (_) {
      // 落到下方复制兜底。
    }
  }
  await Clipboard.setData(ClipboardData(text: copyOnFail));
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text('已复制：$copyOnFail')));
}
