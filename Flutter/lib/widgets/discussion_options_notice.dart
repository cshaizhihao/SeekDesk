// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' show Tooltip;

import 'glass_chrome.dart';

/// Presentation only: the editor owns request identity and retains its fields
/// while login, verification and metadata retries happen independently.
class DiscussionOptionsNotice extends StatelessWidget {
  const DiscussionOptionsNotice({
    required this.phase,
    required this.busy,
    this.message,
    required this.onRetry,
    required this.onOpenVerification,
    super.key,
  });

  final String phase;
  final bool busy;
  final String? message;
  final VoidCallback? onRetry, onOpenVerification;

  @override
  Widget build(BuildContext context) {
    final detail = message?.trim() ?? '';
    if (phase == 'ready' && detail.isEmpty) return const SizedBox.shrink();
    final colors = DeskColors(context);
    final loading = phase == 'loading';
    final signedOut = phase == 'signedOut';
    final verification = phase == 'verification';
    final needsAccess = signedOut || verification;
    final retryable = !loading && phase != 'ready' && phase != 'expired';
    final title = switch (phase) {
      'loading' => '正在读取发布选项',
      'ready' => '发布选项提示',
      'signedOut' => '登录后可读取发布选项',
      'verification' => '需要完成站点验证',
      'expired' => '账号已变更',
      _ => '暂时无法读取发布选项',
    };
    final description = detail.isNotEmpty
        ? detail
        : switch (phase) {
            'signedOut' => '请先登录 NodeSeek，再返回这里重试。当前正文会保留。',
            'verification' => '完成验证后，返回这里重新读取板块与阅读权限。当前正文会保留。',
            'loading' || 'ready' => '',
            _ => '请重试读取板块与阅读权限。当前正文会保留。',
          };
    return TextFieldTapRegion(
      child: DeskGlassPanel(
        quiet: true,
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              liveRegion: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (loading || busy) ...[
                        const CupertinoActivityIndicator(radius: 7),
                        const SizedBox(width: 9),
                      ],
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            color: colors.ink,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Tooltip(
                      message: description,
                      excludeFromSemantics: true,
                      waitDuration: const Duration(milliseconds: 600),
                      child: Text(
                        description,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.secondary,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (retryable) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (needsAccess)
                    DeskButton(
                      signedOut ? '打开登录窗口' : '打开验证窗口',
                      width: 142,
                      icon: CupertinoIcons.arrow_up_right_square,
                      onTap: busy ? null : onOpenVerification,
                    ),
                  DeskButton(
                    signedOut
                        ? '登录后重试'
                        : verification
                        ? '验证后重试'
                        : '重试',
                    width: needsAccess ? 126 : 82,
                    icon: CupertinoIcons.arrow_clockwise,
                    onTap: busy ? null : onRetry,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
