import 'dart:ui';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/forum_post_list.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

class Fixture extends NativeClient {
  final calls = <(String, JsonMap)>[];
  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) async {
    calls.add((method, {...args}));
    return {};
  }
}

void main() {
  late Fixture native;
  late AppState state;
  late ScrollController scroll;
  late List<String> opened;
  var allowed = true;
  Future<void> mount(
    WidgetTester tester, {
    double width = 500,
    double size = 15,
    double scale = 1,
    String category = '技术',
    String? author,
  }) async {
    native = Fixture();
    state = AppState(client: native)..connecting = false;
    state.domains['workspace'] = {
      'showReader': false,
      'tabs': <JsonMap>[],
      'posts': [
        for (var i = 0; i < 40; i++)
          {
            'id': '$i',
            'url': 'https://www.nodeseek.com/post-$i-1',
            'title': 'Post $i',
            'author': author ?? 'Author $i',
            'dateLabel': '3 分钟前',
            'categoryLabel': category,
            'featured': i == 0,
            'readingRank': i == 0 ? 255 : null,
          },
      ],
    };
    state.domains['settings'] = {'workspace.listTextSize': size};
    state.domains['extensions'] = {'items': <JsonMap>[]};
    scroll = ScrollController();
    opened = [];
    allowed = true;
    await tester.pumpWidget(
      CupertinoApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: CupertinoPageScaffold(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: 300,
              child: ForumPostList(
                state: state,
                controller: scroll,
                canInteract: () => allowed,
                onOpen: (post) => opened.add(post.url),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      scroll.dispose();
      state.dispose();
    });
  }

  testWidgets(
    'original left avatar and two-level metadata; narrow large text fits',
    (tester) async {
      await mount(tester, width: 300, size: 24);
      final title = tester.getRect(find.text('Post 0'));
      final avatar = tester.getRect(find.byType(NativeAvatar).first);
      expect(avatar.right, lessThan(title.left));
      expect(avatar.width, 34);
      expect((avatar.top - title.top).abs(), lessThan(4));
      expect(
        tester.widget<Text>(find.text('Post 0')).style?.fontWeight,
        FontWeight.w400,
      );
      expect(tester.widget<Text>(find.text('Post 0')).style?.fontSize, 24);
      expect(tester.widget<Text>(find.text('Post 0')).maxLines, 3);
      expect(find.text('Author 0 · 3 分钟前'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('Author 0 · 3 分钟前')).style?.fontSize,
        14,
      );
      final category = tester.widget<Text>(find.text('技术').first);
      expect(category.style?.fontSize, 12);
      expect(
        category.style?.color,
        DeskColors(tester.element(find.text('技术').first)).secondary,
      );
      expect(find.byIcon(CupertinoIcons.suit_diamond), findsOneWidget);
      expect(find.text('私有'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [360.0, 420.0]) {
    testWidgets(
      'long author and category stay inside $width at double text size',
      (tester) async {
        const category = '一个特别长而且需要截断的测试分类名称';
        const author = 'A very long forum member name';
        await mount(
          tester,
          width: width,
          size: 24,
          scale: 2,
          category: category,
          author: author,
        );
        final row = tester.getRect(find.byType(ForumPostRow).first);
        final badge = tester.getRect(find.text(category).first);
        final metadata = tester.getRect(find.text('$author · 3 分钟前').first);
        expect(badge.right, lessThanOrEqualTo(row.right));
        expect(metadata.width, greaterThan(70));
        expect(metadata.right, lessThanOrEqualTo(row.right));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'arrows reveal lazy rows, Enter opens, Command Enter never loads reader',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('Post 0'));
      opened.clear();
      for (var i = 0; i < 14; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      expect(scroll.offset, greaterThan(0));
      expect(
        tester.getRect(find.text('Post 14')).bottom,
        lessThanOrEqualTo(300),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      final before = state.navigationRevision;
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(opened, isEmpty);
      expect(state.navigationRevision, before);
      expect(native.calls, hasLength(1));
      expect(native.calls.single.$1, 'reader.open');
      expect(native.calls.single.$2, {
        'url': 'https://www.nodeseek.com/post-14-1',
        'background': true,
      });
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(opened, ['https://www.nodeseek.com/post-14-1']);
      allowed = false;
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(opened, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'secondary-click menu is anchored and background action is read-free',
    (tester) async {
      await mount(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Post 0')),
        kind: PointerDeviceKind.mouse,
        buttons: 2,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('在后台打开'), findsOneWidget);
      expect(find.text('管理记录查询'), findsNothing);
      await tester.tap(find.text('在后台打开'));
      await tester.pumpAndSettle();
      expect(native.calls, hasLength(1));
      expect(native.calls.single.$2['background'], true);
      expect(opened, isEmpty);
    },
  );

  testWidgets('menu result is discarded after listing changes', (tester) async {
    await mount(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Post 0')),
      kind: PointerDeviceKind.mouse,
      buttons: 2,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    state.domains['workspace'] = {
      ...state.domain('workspace'),
      'query': 'changed',
    };
    await tester.tap(find.text('在后台打开'));
    await tester.pumpAndSettle();
    expect(native.calls, isEmpty);
  });
  testWidgets('four-action menu stays inside a short window near the bottom', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(500, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await mount(tester);
    state.domains['extensions'] = {
      'items': [
        {'id': 'block', 'active': true},
        {'id': 'rulings', 'active': true},
      ],
    };
    final row = find.text('Post 2');
    final gesture = await tester.startGesture(
      tester.getCenter(row),
      kind: PointerDeviceKind.mouse,
      buttons: 2,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    final bounds = tester.getRect(find.byType(DeskDocument));
    expect(bounds.bottom, lessThanOrEqualTo(292));
    expect(find.text('屏蔽此用户').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
