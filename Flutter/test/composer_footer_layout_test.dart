// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/composer_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/markdown_editor_controls.dart';

const _longStatus =
    '上一次发布结果尚未确认，请先检查帖子是否已经发布。当前草稿仍保存在本机，确认后再决定是否重试；'
    '这条较长的状态信息应完整保留在提示中，不挤开底部的放弃编辑和发布操作。';

class _LayoutNative extends NativeClient {
  _LayoutNative({this.failRead = false});
  final bool failRead;
  final calls = <String>[];
  final unexpected = <String>[];

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add(method);
    switch (method) {
      case 'images.draftReferences':
        return {};
      case 'discussion.getDraft':
      case 'reader.replyDraft':
        if (failRead) {
          throw const NativeFailure('fixture_read', 'Local read failure');
        }
        return {
          'title': '本地布局检查',
          'content': '现有草稿，布局检查不会更改或发布。',
          'category': 'tech',
          'rank': 0,
        };
      case 'discussion.loadOptions':
        return {
          'phase': 'ready',
          'ready': true,
          'category': 'tech',
          'rank': 0,
          'maxRank': 3,
          'categories': [
            {'id': 'tech', 'title': '技术'},
          ],
          'lastSubmissionMessage': _longStatus,
        };
      default:
        unexpected.add(method);
        throw StateError(
          'Layout checks cannot write drafts or send content: $method',
        );
    }
  }
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);

Future<AppState> _mount(
  WidgetTester tester,
  _LayoutNative native, {
  required bool reply,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 800));
  final state = AppState(client: native);
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        home: ComposerScreen(state: state, topicID: reply ? '17' : null),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

Future<void> _dispose(
  WidgetTester tester,
  AppState state,
  _LayoutNative native,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  state.dispose();
  await tester.pump(const Duration(seconds: 1));
  await tester.binding.setSurfaceSize(null);
  expect(native.unexpected, isEmpty);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final reply in [false, true]) {
    testWidgets(
      '${reply ? 'reply' : 'discussion'} keeps discard beside the green send action across widths',
      (tester) async {
        final native = _LayoutNative();
        final state = await _mount(tester, native, reply: reply);
        try {
          final sendLabel = reply ? '发送回复' : '发布帖子';
          final title = find.text(reply ? '写回复' : '发布新帖');
          for (final size in [
            const Size(1200, 800),
            const Size(780, 540),
            const Size(520, 540),
          ]) {
            await tester.binding.setSurfaceSize(size);
            await tester.pumpAndSettle();
            expect(_button('放弃编辑'), findsOneWidget);
            expect(_button('保存并关闭').hitTestable(), findsOneWidget);
            expect(_button(sendLabel).hitTestable(), findsOneWidget);
            final discard = tester.getRect(_button('放弃编辑'));
            final send = tester.getRect(_button(sendLabel));
            final close = tester.getRect(_button('保存并关闭'));
            final status = tester.getRect(find.byType(MarkdownStatus));
            final editor = tester.getRect(
              find.byKey(const ValueKey('markdown-workspace-editor')),
            );
            expect(send.left - discard.right, closeTo(10, .01));
            expect(discard.top, closeTo(send.top, .01));
            expect(discard.bottom, closeTo(send.bottom, .01));
            expect(discard.top, greaterThanOrEqualTo(editor.bottom));
            expect(send.right, lessThanOrEqualTo(size.width - 16));
            expect(send.bottom, lessThanOrEqualTo(size.height - 16));
            expect(close.bottom, lessThan(editor.top));
            expect(
              tester.getRect(title).center.dy,
              closeTo(close.center.dy, 2),
            );
            expect(tester.widget<DeskButton>(_button('放弃编辑')).onTap, isNotNull);
            expect(
              tester.widget<DeskButton>(_button('保存并关闭')).onTap,
              isNotNull,
            );
            expect(
              tester.widget<DeskButton>(_button(sendLabel)).tint,
              CupertinoColors.systemGreen,
            );
            expect(editor.height, greaterThan(80));
            if (size.width == 520) {
              expect(status.bottom, lessThan(discard.top));
            } else {
              expect(status.right, lessThan(discard.left));
            }
            if (!reply) {
              expect(
                tester.widget<MarkdownStatus>(find.byType(MarkdownStatus)).text,
                _longStatus,
              );
            }
            expect(tester.takeException(), isNull);
          }
        } finally {
          await _dispose(tester, state, native);
        }
      },
    );
  }

  testWidgets(
    'a failed draft read retains the close and discard exits after moving discard',
    (tester) async {
      final native = _LayoutNative(failRead: true);
      final state = await _mount(tester, native, reply: true);
      try {
        await tester.binding.setSurfaceSize(const Size(780, 540));
        await tester.pumpAndSettle();
        expect(find.text('无法打开草稿'), findsOneWidget);
        expect(_button('放弃编辑').hitTestable(), findsOneWidget);
        expect(_button('保存并关闭').hitTestable(), findsOneWidget);
        expect(tester.widget<DeskButton>(_button('放弃编辑')).onTap, isNotNull);
        expect(
          tester.getRect(_button('放弃编辑')).top,
          greaterThan(tester.getRect(_button('保存并关闭')).bottom),
        );
        expect(_button('发送回复'), findsNothing);
        expect(native.calls, ['reader.replyDraft', 'images.draftReferences']);
        expect(tester.takeException(), isNull);
      } finally {
        await _dispose(tester, state, native);
      }
    },
  );
}
