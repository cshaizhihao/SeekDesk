import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/composer_media.dart';
import 'package:seekdesk_flutter/widgets/composer_sticker_picker.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);
const _packs = <JsonMap>[
  {
    'id': 'ac',
    'title': 'AC 娘',
    'items': [
      {
        'id': 'ac01',
        'label': 'AC 娘 01',
        'url': 'https://www.nodeseek.com/static/image/sticker/ac/01.png',
        'insertion': ' :ac01: ',
      },
    ],
  },
  {
    'id': 'yct',
    'title': '洋葱头',
    'items': [
      {
        'id': 'yct001',
        'label': '洋葱头 001',
        'url': 'https://www.nodeseek.com/static/image/sticker/yct/001.gif',
        'insertion': ' :yct001: ',
      },
    ],
  },
];

JsonMap _group({
  String id = 'favorites',
  String name = '收藏',
  bool empty = false,
}) => {
  'id': id,
  'name': name,
  'items': empty
      ? <JsonMap>[]
      : <JsonMap>[
          {'id': 'cat', 'label': '小猫'},
        ],
};

class _PickerNative extends NativeClient {
  final calls = <(String, JsonMap)>[];
  List<JsonMap> groups = [_group()];
  Future<JsonMap> Function(String, JsonMap)? respond;

  int count(String method) => calls.where((call) => call.$1 == method).length;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    if (respond != null) return respond!(method, arguments);
    return defaultResponse(method, arguments);
  }

  JsonMap defaultResponse(String method, JsonMap arguments) {
    switch (method) {
      case 'stickers.custom.list':
        return {'groups': groups};
      case 'stickers.custom.create':
        groups = [
          ...groups,
          _group(id: 'created', name: arguments['name'] as String, empty: true),
        ];
        return {'groupID': 'created', 'groups': groups};
      case 'stickers.custom.remove':
        groups = [
          for (final group in groups)
            if (group['id'] == arguments['groupID'])
              {...group, 'items': <JsonMap>[]}
            else
              group,
        ];
        return {'groups': groups};
      case 'stickers.custom.thumbnail':
        return {'bytes': _pixel};
      case 'images.load':
        return {'bytes': _pixel, 'width': 1, 'height': 1};
      case 'request.cancel':
        return {};
      default:
        throw StateError('Unexpected service: $method');
    }
  }
}

void main() {
  late _PickerNative native;
  late AppState state;
  late bool disposed;
  ComposerStickerSelection? selected;

  setUp(() {
    native = _PickerNative();
    state = AppState(client: native);
    disposed = false;
    selected = null;
  });
  void disposeState() {
    if (disposed) return;
    disposed = true;
    state.dispose();
  }

  tearDown(disposeState);

  Finder button(String label) => find.byWidgetPredicate(
    (widget) => widget is DeskButton && widget.label == label,
  );

  Future<void> pump(WidgetTester tester) async {
    await tester.pump();
    // Glass springs can outlive their nominal duration; bounded pumps avoid
    // waiting for deliberately pending native operations in these fixtures.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
  }

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(900, 700),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(
          home: Builder(
            builder: (context) => CupertinoPageScaffold(
              child: Center(
                child: DeskButton(
                  '打开表情',
                  onTap: () async {
                    selected = await showComposerStickerPicker(
                      context: context,
                      state: state,
                      packs: _packs,
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(button('打开表情'));
    await pump(tester);
    final route = ModalRoute.of(
      tester.element(find.byType(ComposerStickerPicker)),
    )!;
    for (var frame = 0; frame < 40 && route.animation!.isAnimating; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(route.animation!.status, AnimationStatus.completed);
  }

  Future<void> selectGroup(WidgetTester tester, int index) async {
    tester
        .widget<GlassSegmentedControl>(find.byType(GlassSegmentedControl))
        .onSegmentSelected(index);
    await pump(tester);
  }

  Future<void> close(WidgetTester tester) async {
    final action = tester
        .widget<DeskIcon>(
          find.byWidgetPredicate(
            (widget) => widget is DeskIcon && widget.label == '关闭表情',
          ),
        )
        .onTap;
    action?.call();
    await pump(tester);
    if (action == null) return;
    for (
      var frame = 0;
      frame < 40 && find.byType(ComposerStickerPicker).evaluate().isNotEmpty;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(ComposerStickerPicker), findsNothing);
  }

  testWidgets(
    'official selection works while the custom library is unavailable',
    (tester) async {
      native.respond = (method, args) async {
        if (method == 'stickers.custom.list') {
          throw const NativeFailure(
            'fixture',
            'Do not display provider details',
          );
        }
        return native.defaultResponse(method, args);
      };
      await open(tester);
      expect(find.text('自定义表情暂不可用。'), findsOneWidget);
      expect(find.textContaining('provider details'), findsNothing);
      expect(state.message, isNull);
      expect(state.pending, isEmpty);
      expect(find.text('AC 娘'), findsWidgets);
      expect(find.text('洋葱头'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('official-sticker-ac01')));
      await pump(tester);
      expect(selected, isA<OfficialStickerSelection>());
      expect((selected as OfficialStickerSelection).insertion, ' :ac01: ');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('local library retry preserves the official panel', (
    tester,
  ) async {
    var failures = 1;
    native.respond = (method, args) async {
      if (method == 'stickers.custom.list' && failures-- > 0) {
        throw const NativeFailure('fixture', 'Private native path');
      }
      return native.defaultResponse(method, args);
    };
    await open(tester);
    await tester.tap(button('重试'));
    await pump(tester);
    expect(native.count('stickers.custom.list'), 2);
    expect(find.text('自定义表情暂不可用。'), findsNothing);
    await selectGroup(tester, 2);
    expect(
      find.byKey(const ValueKey('custom-sticker-favorites-cat')),
      findsOneWidget,
    );
    expect(native.count('stickers.custom.thumbnail'), 1);
    expect(state.message, isNull);
    await close(tester);
  });

  testWidgets(
    'custom selection returns IDs and switching groups reuses thumbnails',
    (tester) async {
      await open(tester);
      await selectGroup(tester, 2);
      await selectGroup(tester, 0);
      await selectGroup(tester, 2);
      expect(native.count('stickers.custom.thumbnail'), 1);
      await tester.tap(
        find.byKey(const ValueKey('custom-sticker-favorites-cat')),
      );
      await pump(tester);
      final custom = selected as CustomStickerSelection;
      expect(custom.groupID, 'favorites');
      expect(custom.itemID, 'cat');
      expect(native.calls.where((call) => call.$1.contains('upload')), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'creating a group selects its empty import view and rejects duplicate names',
    (tester) async {
      await open(tester);
      await tester.tap(button('新建分组'));
      await pump(tester);
      await tester.enterText(
        find.byKey(const ValueKey('sticker-group-name')),
        '收藏',
      );
      await tester.tap(button('创建'));
      await pump(tester);
      expect(find.text('已经有同名分组。'), findsOneWidget);
      expect(native.count('stickers.custom.create'), 0);

      await tester.enterText(
        find.byKey(const ValueKey('sticker-group-name')),
        '  新收藏  ',
      );
      await tester.tap(button('创建'));
      await pump(tester);
      expect(native.count('stickers.custom.create'), 1);
      expect(
        native.calls
            .firstWhere((call) => call.$1 == 'stickers.custom.create')
            .$2['name'],
        '新收藏',
      );
      expect(find.text('还没有表情，导入几张喜欢的图片吧。'), findsOneWidget);
      expect(button('导入图片…'), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets(
    'import holds close and group switching, then reports partial success',
    (tester) async {
      final importing = Completer<JsonMap>();
      native.respond = (method, args) async => method == 'system.importStickers'
          ? importing.future
          : native.defaultResponse(method, args);
      await open(tester);
      await selectGroup(tester, 2);
      await tester.tap(button('导入图片…'));
      await pump(tester);
      expect(native.count('system.importStickers'), 1);
      expect(tester.widget<DeskButton>(button('新建分组')).onTap, isNull);
      await close(tester);
      expect(find.byType(ComposerStickerPicker), findsOneWidget);
      await selectGroup(tester, 0);
      expect(
        find.byKey(const ValueKey('custom-sticker-favorites-cat')),
        findsOneWidget,
      );
      final pickerContext = tester.element(find.byType(ComposerStickerPicker));
      expect(await Navigator.of(pickerContext).maybePop(), isTrue);
      await pump(tester);
      expect(find.byType(ComposerStickerPicker), findsOneWidget);

      importing.complete({
        'importedCount': 1,
        'skippedCount': 2,
        'groups': native.groups,
      });
      await pump(tester);
      expect(find.text('已导入 1 张，跳过 2 张无法读取或过大的图片。'), findsOneWidget);
      await close(tester);
      expect(find.byType(ComposerStickerPicker), findsNothing);
    },
  );

  testWidgets(
    'cancelled import leaves the group unchanged and unlocks controls',
    (tester) async {
      native.respond = (method, args) async => method == 'system.importStickers'
          ? {'cancelled': true}
          : native.defaultResponse(method, args);
      await open(tester);
      await selectGroup(tester, 2);
      await tester.tap(button('导入图片…'));
      await pump(tester);
      expect(
        find.byKey(const ValueKey('custom-sticker-favorites-cat')),
        findsOneWidget,
      );
      expect(find.textContaining('已导入'), findsNothing);
      expect(tester.widget<DeskButton>(button('新建分组')).onTap, isNotNull);
      await close(tester);
    },
  );

  testWidgets('remove only sends local IDs and updates the selected group', (
    tester,
  ) async {
    await open(tester);
    await selectGroup(tester, 2);
    await tester.tap(
      find.byKey(const ValueKey('remove-sticker-favorites-cat')),
    );
    await pump(tester);
    expect(native.count('stickers.custom.remove'), 1);
    final args = native.calls
        .firstWhere((call) => call.$1 == 'stickers.custom.remove')
        .$2;
    expect(args['groupID'], 'favorites');
    expect(args['itemID'], 'cat');
    expect(args.containsKey('path'), isFalse);
    expect(
      find.byKey(const ValueKey('custom-sticker-favorites-cat')),
      findsNothing,
    );
    expect(find.text('还没有表情，导入几张喜欢的图片吧。'), findsOneWidget);
    expect(selected, isNull);
    await close(tester);
  });

  testWidgets('account change cancels import and rejects its late result', (
    tester,
  ) async {
    final importing = Completer<JsonMap>();
    native.respond = (method, args) async => method == 'system.importStickers'
        ? importing.future
        : native.defaultResponse(method, args);
    await open(tester);
    await selectGroup(tester, 2);
    await tester.tap(button('导入图片…'));
    await pump(tester);
    final request = native.calls
        .firstWhere((call) => call.$1 == 'system.importStickers')
        .$2['requestId'];
    native.accessRevision++;
    // A real session snapshot notifies AppState listeners; this fixture uses
    // an unrelated notification solely to exercise the same public boundary.
    state.showMessage('fixture account notification');
    await pump(tester);
    expect(
      native.calls.where(
        (call) =>
            call.$1 == 'request.cancel' && call.$2['requestId'] == request,
      ),
      hasLength(1),
    );
    expect(find.text('账号已变更，请关闭后重新打开表情。'), findsOneWidget);
    importing.complete({
      'importedCount': 1,
      'skippedCount': 0,
      'groups': [_group(id: 'late', name: '迟到分组')],
    });
    await pump(tester);
    expect(find.text('迟到分组'), findsNothing);
    expect(selected, isNull);
    await selectGroup(tester, 0);
    expect(find.byKey(const ValueKey('official-sticker-ac01')), findsNothing);
    await close(tester);
    disposeState();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'route disposal cancels a pending local thumbnail without late UI errors',
    (tester) async {
      final thumbnail = Completer<JsonMap>();
      native.respond = (method, args) async =>
          method == 'stickers.custom.thumbnail'
          ? thumbnail.future
          : native.defaultResponse(method, args);
      await open(tester);
      await selectGroup(tester, 2);
      final request = native.calls
          .firstWhere((call) => call.$1 == 'stickers.custom.thumbnail')
          .$2['requestId'];
      await tester.pumpWidget(const SizedBox.shrink());
      await pump(tester);
      expect(
        native.calls.where(
          (call) =>
              call.$1 == 'request.cancel' && call.$2['requestId'] == request,
        ),
        hasLength(1),
      );
      thumbnail.complete({'bytes': _pixel});
      await pump(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed local thumbnail retries without selecting or uploading it',
    (tester) async {
      var thumbnailCalls = 0;
      native.respond = (method, args) async {
        if (method == 'stickers.custom.thumbnail' && thumbnailCalls++ == 0) {
          throw const NativeFailure(
            'fixture',
            'Do not expose a local file path',
          );
        }
        return native.defaultResponse(method, args);
      };
      await open(tester);
      await selectGroup(tester, 2);
      final retry = find.byWidgetPredicate(
        (widget) =>
            widget is CupertinoButton &&
            widget.child is Semantics &&
            (widget.child as Semantics).properties.label == '重试表情缩略图',
      );
      await tester.tap(retry);
      await pump(tester);
      expect(native.count('stickers.custom.thumbnail'), 2);
      expect(selected, isNull);
      expect(find.byType(ComposerStickerPicker), findsOneWidget);
      expect(find.textContaining('local file path'), findsNothing);
      expect(state.message, isNull);
      await close(tester);
    },
  );

  testWidgets('late custom list after account change cannot add new groups', (
    tester,
  ) async {
    final listing = Completer<JsonMap>();
    native.respond = (method, args) async => method == 'stickers.custom.list'
        ? listing.future
        : native.defaultResponse(method, args);
    await open(tester);
    final request = native.calls
        .firstWhere((call) => call.$1 == 'stickers.custom.list')
        .$2['requestId'];
    native.accessRevision++;
    state.showMessage('fixture account notification');
    await pump(tester);
    expect(
      native.calls.where(
        (call) =>
            call.$1 == 'request.cancel' && call.$2['requestId'] == request,
      ),
      hasLength(1),
    );
    listing.complete({
      'groups': [_group(name: '不应出现的分组')],
    });
    await pump(tester);
    expect(find.text('不应出现的分组'), findsNothing);
    expect(find.text('账号已变更，请关闭后重新打开表情。'), findsOneWidget);
    expect(selected, isNull);
    await close(tester);
    disposeState();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('actual PNG decode failure retries the cached local bytes', (
    tester,
  ) async {
    await tester.runAsync(() async {
      var corrupt = true;
      native.respond = (method, args) async =>
          method == 'stickers.custom.thumbnail'
          ? {
              'bytes': corrupt
                  ? Uint8List.fromList([0x53, 0x44, 0, 1, 2])
                  : _pixel,
            }
          : native.defaultResponse(method, args);
      await open(tester);
      await selectGroup(tester, 2);

      Future<bool> decode() async {
        final image = tester.widget<Image>(
          find.descendant(
            of: find.byKey(const ValueKey('custom-sticker-favorites-cat')),
            matching: find.byType(Image),
          ),
        );
        final stream = image.image.resolve(ImageConfiguration.empty);
        final complete = Completer<bool>();
        final listener = ImageStreamListener(
          (info, synchronous) {
            info.dispose();
            if (!complete.isCompleted) complete.complete(true);
          },
          onError: (Object error, StackTrace? stack) {
            if (!complete.isCompleted) complete.complete(false);
          },
        );
        stream.addListener(listener);
        try {
          return await complete.future.timeout(const Duration(seconds: 5));
        } finally {
          stream.removeListener(listener);
        }
      }

      expect(await decode(), isFalse);
      await tester.pump();
      final retry = find.byWidgetPredicate(
        (widget) =>
            widget is CupertinoButton &&
            widget.child is Semantics &&
            (widget.child as Semantics).properties.label == '重试表情缩略图',
      );
      expect(retry, findsOneWidget);
      expect(native.count('stickers.custom.thumbnail'), 1);
      corrupt = false;
      await tester.tap(retry);
      await tester.pump();
      await tester.pump();
      expect(native.count('stickers.custom.thumbnail'), 2);
      expect(await decode(), isTrue);
      await tester.pump();
      expect(retry, findsNothing);
      expect(selected, isNull);
      expect(state.message, isNull);
      await close(tester);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets(
    'compact picker fits a small window and long feedback scrolls inside it',
    (tester) async {
      native.respond = (method, args) async => method == 'system.importStickers'
          ? {'importedCount': 3, 'skippedCount': 12, 'groups': native.groups}
          : native.defaultResponse(method, args);
      await open(tester, size: const Size(320, 300));
      final panel = tester.getRect(
        find.byKey(const ValueKey('composer-sticker-panel')),
      );
      expect(panel.left, greaterThanOrEqualTo(12));
      expect(panel.right, lessThanOrEqualTo(308));
      expect(panel.height, lessThanOrEqualTo(276));
      await selectGroup(tester, 2);
      await tester.ensureVisible(button('导入图片…'));
      await tester.tap(button('导入图片…'));
      await pump(tester);
      expect(find.textContaining('跳过 12 张'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );
}
