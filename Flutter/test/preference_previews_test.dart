import 'dart:ui' show SemanticsAction;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';
import 'package:seekdesk_flutter/widgets/forum_post_list.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/preference_previews.dart';
import 'package:seekdesk_flutter/widgets/reader_context.dart';

const _title = '分享一次晚高峰的三网线路实测';
const _body = '这是晚高峰的实测记录。电信和联通的延迟比较稳定，移动偶尔出现波动。';
const _settings = <String, dynamic>{
  'workspace.readerTextSize': 19.0,
  'workspace.listTextSize': 20.0,
  'workspace.floorAuthorScale': 135.0,
  'workspace.boardTextSize': 18.0,
  'workspace.rankingTextSize': 17.0,
};

/// No platform fallback: previews must remain local even if a real renderer
/// later gains a request in its lifecycle or a new interactive child.
class _PreviewNative extends NativeClient {
  _PreviewNative()
    : super(methods: const MethodChannel('seekdesk.test.preference-previews'));

  final calls = <String>[];

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add(method);
    throw StateError('Unexpected preference preview request: $method');
  }
}

Future<void> _mount(
  WidgetTester tester,
  AppState state, {
  double width = 360,
  double textScale = 1,
  double bodySize = 15,
  double authorScale = 100,
  double titleSize = 15,
  double boardSize = 13,
  double rankingSize = 12,
  bool compact = false,
  FocusNode? before,
  FocusNode? after,
}) async {
  await tester.pumpWidget(
    CupertinoApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
          ),
          child: CupertinoPageScaffold(
            child: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: width,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (before != null)
                        Focus(focusNode: before, child: const Text('前一个控件')),
                      PreferenceReaderPreview(
                        state: state,
                        bodySize: bodySize,
                        authorScale: authorScale,
                      ),
                      const SizedBox(height: 12),
                      PreferenceListPreview(
                        state: state,
                        titleSize: titleSize,
                        compact: compact,
                      ),
                      const SizedBox(height: 12),
                      PreferenceSidebarPreview(
                        boardSize: boardSize,
                        rankingSize: rankingSize,
                      ),
                      if (after != null)
                        Focus(focusNode: after, child: const Text('下一个控件')),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _PreviewNative native;
  late AppState state;

  setUp(() {
    native = _PreviewNative();
    state = AppState(client: native)..connecting = false;
    state.domains['settings'] = {..._settings};
  });

  tearDown(() {
    expect(native.calls, isEmpty);
    expect(state.domain('settings'), _settings);
    state.dispose();
  });

  for (final sample in [(240.0, 2.0), (360.0, 1.3), (620.0, 1.0)]) {
    testWidgets(
      'local previews fit ${sample.$1} width at ${sample.$2} text scale with maximum sizes',
      (tester) async {
        await _mount(
          tester,
          state,
          width: sample.$1,
          textScale: sample.$2,
          bodySize: 24,
          authorScale: 160,
          titleSize: 24,
          boardSize: 22,
          rankingSize: 22,
        );
        for (final type in [
          PreferenceReaderPreview,
          PreferenceListPreview,
          PreferenceSidebarPreview,
        ]) {
          final preview = find.byType(type);
          final bounds = tester.getRect(preview);
          expect(bounds.width, sample.$1);
          expect(
            MediaQuery.textScalerOf(tester.element(preview)).scale(13),
            13 * sample.$2,
          );
          final labels = find.descendant(
            of: preview,
            matching: find.byType(Text),
          );
          for (var index = 0; index < labels.evaluate().length; index++) {
            final rect = tester.getRect(labels.at(index));
            expect(rect.left, greaterThanOrEqualTo(bounds.left));
            expect(rect.right, lessThanOrEqualTo(bounds.right));
            expect(rect.top, greaterThanOrEqualTo(bounds.top));
            expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
          }
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'size changes update the real text and avatar layout without changing preferences',
    (tester) async {
      await _mount(tester, state, width: 360);
      final reader = find.byType(PreferenceReaderPreview);
      final list = find.byType(PreferenceListPreview);
      Finder avatar(Finder parent) =>
          find.descendant(of: parent, matching: find.byType(NativeAvatar));
      final readerElement = tester.element(find.byType(ReaderFloorContext));
      final listElement = tester.element(find.byType(ForumPostRow));
      final initialReaderHeight = tester.getSize(reader).height;
      expect(tester.getSize(avatar(reader)).width, 35);
      expect(tester.getSize(avatar(list)).width, 30);

      await _mount(
        tester,
        state,
        width: 360,
        bodySize: 24,
        authorScale: 160,
        titleSize: 24,
        boardSize: 22,
        rankingSize: 20,
        compact: true,
      );
      expect(
        tester.element(find.byType(ReaderFloorContext)),
        same(readerElement),
      );
      expect(tester.element(find.byType(ForumPostRow)), same(listElement));
      expect(tester.getSize(avatar(reader)).width, 56);
      expect(tester.getSize(avatar(list)).width, 34);
      expect(tester.getSize(reader).height, greaterThan(initialReaderHeight));
      final body = tester.widget<InlineMarkdown>(
        find.byWidgetPredicate(
          (widget) => widget is InlineMarkdown && widget.text == _body,
        ),
      );
      expect(body.style.fontSize, 24);
      final title = tester.widget<Text>(
        find.descendant(of: list, matching: find.text(_title)),
      );
      expect(title.style?.fontSize, 24);
      expect(title.maxLines, 2);
      expect(
        tester.widget<ForumPostRow>(find.byType(ForumPostRow)).compact,
        isTrue,
      );
      expect(tester.widget<Text>(find.text('技术交流')).style?.fontSize, 22);
      final sidebarTitle = tester.widget<Text>(
        find.descendant(
          of: find.byType(PreferenceSidebarPreview),
          matching: find.text(_title),
        ),
      );
      expect(sidebarTitle.style?.fontSize, 20);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'previews expose one description each and cannot receive focus or activate native work',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final before = FocusNode(), after = FocusNode();
      try {
        await _mount(tester, state, before: before, after: after);
        for (final label in [
          '阅读预览，正文 15 点，作者栏 100%',
          '帖子列表预览，标题 15 点，舒适布局',
          '侧栏预览，版块 13 点，热榜 12 点',
        ]) {
          final description = find.bySemanticsLabel(label);
          expect(description, findsOneWidget);
          final data = tester.getSemantics(description).getSemanticsData();
          expect(data.hasAction(SemanticsAction.tap), isFalse);
          expect(data.hasAction(SemanticsAction.longPress), isFalse);
          expect(data.hasAction(SemanticsAction.increase), isFalse);
        }
        expect(find.bySemanticsLabel('示例用户，查看资料'), findsNothing);
        await tester.tap(
          find.descendant(
            of: find.byType(PreferenceListPreview),
            matching: find.text(_title),
          ),
          warnIfMissed: false,
        );
        await tester.tap(find.text('示例用户').first, warnIfMissed: false);
        before.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(FocusManager.instance.primaryFocus, same(after));
        expect(native.calls, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        before.dispose();
        after.dispose();
        semantics.dispose();
      }
    },
  );
}
