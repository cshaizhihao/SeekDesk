import 'dart:async';
import 'dart:ui' show SemanticsAction;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/extensions_screen.dart';
import 'package:seekdesk_flutter/screens/tools_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

const _titles = {
  'hot': 'NodeSeek 热榜',
  'office': '摸鱼老板键',
  'keywords': '关键词监控',
  'value': '剩余价值计算器',
};

class _Native extends NativeClient {
  _Native({this.includeAttendance = false})
    : super(methods: const MethodChannel('seekdesk.test.extension-layout'));
  final bool includeAttendance;
  Set<String> installed = {'hot', 'office', 'keywords'};
  final enabled = <String>{'hot', 'office', 'keywords', 'value'};
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  bool failInstall = false, longText = false;
  int unread = 12;
  Completer<JsonMap>? pendingEnable;
  JsonMap configs = {
    'office': {'title': 'Fixture sheet', 'button': '工作表', 'key': '9'},
    'keywords': {
      'words': '日本+VPS，测评',
      'note': '',
      'notificationAccess': 2,
      'systemNotifications': false,
    },
  };
  JsonMap get snapshot => {
    'items': [
      for (final entry in [
        ..._titles.entries,
        if (includeAttendance) const MapEntry('attendance', '每日签到'),
      ])
        {
          'id': entry.key,
          'title': longText
              ? '${entry.value} 非常长的扩展标题 LongUnbrokenExtensionTitle'
              : entry.value,
          'description': longText
              ? '很长的说明需要在局部窄栏安全换行。LongUnbrokenDescriptionAcrossTheWholeAvailableCardWidth'
              : 'Local extension fixture description',
          'installed': installed.contains(entry.key),
          'enabled': enabled.contains(entry.key),
          'active':
              installed.contains(entry.key) && enabled.contains(entry.key),
        },
    ],
    'settings': configs,
    'unread': unread,
    'watchFailed': false,
    'lastCheck': 1794747600000,
    'hits': [
      for (var index = 0; index < 12; index++)
        {
          'post': {
            'id': '${5000 + index}',
            'url': 'https://www.nodeseek.com/post-${5000 + index}-1',
            'title': 'Runtime keyword match $index',
          },
          'words': ['日本', 'VPS'],
        },
    ],
  };
  Iterable<(String, JsonMap)> named(String method) =>
      calls.where((call) => call.$1 == method);

  @override
  Future<JsonMap> call(String method, [JsonMap args = const {}]) async {
    calls.add((method, {...args}));
    switch (method) {
      case 'extensions.list':
        return snapshot;
      case 'extensions.install':
        if (failInstall) {
          throw const NativeFailure(
            'fixture_install',
            'Fixture installation failed',
          );
        }
        installed.add(stringValue(args['id']));
        return snapshot;
      case 'extensions.setEnabled':
        if (pendingEnable != null) return pendingEnable!.future;
        final id = stringValue(args['id']);
        args['enabled'] == true ? enabled.add(id) : enabled.remove(id);
        return snapshot;
      case 'extensions.configure':
        final id = stringValue(args['id']);
        configs = {
          ...configs,
          id: {...jsonMap(configs[id]), ...jsonMap(args['settings'])},
        };
        return snapshot;
      case 'extensions.acknowledgeHits':
        unread = 0;
        return snapshot;
      case 'reader.open':
        return {
          'tabs': [
            {'id': args['id'], 'url': args['url'], 'title': args['title']},
          ],
          'selectedTab': args['id'],
        };
      case 'reader.load':
        return {
          'url': args['url'],
          'thread': {
            'title': 'Opened keyword fixture',
            'root': {'id': '0', 'author': 'Fixture', 'blocks': <JsonMap>[]},
            'replies': <JsonMap>[],
            'pages': <JsonMap>[],
          },
        };
      case 'value.currencies':
        return {
          'items': [
            {'code': 'USD', 'title': 'USD'},
          ],
        };
      case 'value.rate':
        return {'rate': '1'};
    }
    unexpected.add(method);
    throw StateError('Unexpected extension fixture request: $method');
  }
}

Future<AppState> _mount(
  WidgetTester tester,
  _Native native, {
  double width = 960,
  double height = 1200,
  double scale = 1,
  ValueNotifier<double>? liveWidth,
  VoidCallback? rankings,
}) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1500));
  final state = AppState(client: native)..connecting = false;
  state.domains['session'] = {'account': 'signedIn', 'owner': 42};
  state.domains['extensions'] = native.snapshot;
  final pane = liveWidth ?? ValueNotifier(width);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
    state.dispose();
    if (liveWidth == null) pane.dispose();
    await tester.binding.setSurfaceSize(null);
    expect(native.unexpected, isEmpty);
  });
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: true,
              textScaler: TextScaler.linear(scale),
            ),
            child: CupertinoPageScaffold(
              child: Align(
                alignment: Alignment.topCenter,
                child: ValueListenableBuilder<double>(
                  valueListenable: pane,
                  child: ExtensionsScreen(
                    state: state,
                    onOpenRankings: rankings,
                  ),
                  builder: (_, width, child) => SizedBox(
                    key: const ValueKey('local-extension-pane'),
                    width: width,
                    height: height,
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _frames(tester);
  return state;
}

Future<void> _frames(WidgetTester tester) async {
  for (var index = 0; index < 3; index++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder _card(String id) => find.byKey(ValueKey('extension-card-$id'));
Future<void> _open(WidgetTester tester, String id) async {
  await tester.ensureVisible(_card(id));
  await tester.tap(_card(id));
  await _frames(tester);
}

Future<void> _all(WidgetTester tester) async {
  final all = find.textContaining('全部扩展');
  await tester.ensureVisible(all);
  await tester.tap(all);
  await _frames(tester);
}

void _expectSegmentLabelsInside(
  WidgetTester tester,
  Finder control,
  List<String> labels,
) {
  expect(control, findsOneWidget);
  final widget = tester.widget<GlassSegmentedControl>(control);
  final bounds = widget.padding
      .resolve(Directionality.of(tester.element(control)))
      .deflateRect(tester.getRect(control));
  final measured = <Rect>[];
  for (final label in labels) {
    final text = find.descendant(of: control, matching: find.text(label));
    expect(text, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(text);
    expect(paragraph.didExceedMaxLines, isFalse, reason: '$label is truncated');
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: label.length),
    );
    expect(boxes, isNotEmpty, reason: '$label must paint visible text');
    final painted = boxes
        .map((box) => box.toRect())
        .reduce((a, b) => a.expandToInclude(b))
        .shift(paragraph.localToGlobal(Offset.zero));
    // A constrained paragraph's layout box can fit while its glyphs paint
    // outside it. Check both, rather than only the control or overflow errors.
    for (final rect in [tester.getRect(text), painted]) {
      expect(
        rect.left,
        greaterThanOrEqualTo(bounds.left - .01),
        reason: '$label exceeds the control on the left',
      );
      expect(
        rect.right,
        lessThanOrEqualTo(bounds.right + .01),
        reason: '$label exceeds the control on the right',
      );
      expect(
        rect.top,
        greaterThanOrEqualTo(bounds.top - .01),
        reason: '$label exceeds the control above',
      );
      expect(
        rect.bottom,
        lessThanOrEqualTo(bounds.bottom + .01),
        reason: '$label exceeds the control below',
      );
    }
    for (final other in measured) {
      expect(
        painted.overlaps(other),
        isFalse,
        reason: '$label overlaps a peer',
      );
    }
    measured.add(painted);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final width in [360.0, 420.0, 452.0, 453.0]) {
    testWidgets(
      'catalog at local $width fits long cards and 1.3 text without nested actions',
      (tester) async {
        final native = _Native()..longText = true;
        await _mount(tester, native, width: width, scale: 1.3);
        await _all(tester);
        final pane = tester.getRect(
          find.byKey(const ValueKey('local-extension-pane')),
        );
        final cards = <Rect>[];
        for (final id in _titles.keys) {
          final rect = tester.getRect(_card(id));
          expect(rect.left, greaterThanOrEqualTo(pane.left));
          expect(rect.right, lessThanOrEqualTo(pane.right));
          expect(rect.width, greaterThanOrEqualTo(230));
          for (final other in cards) {
            expect(rect.overlaps(other), isFalse);
          }
          cards.add(rect);
          expect(
            find.descendant(of: _card(id), matching: find.byType(GlassSwitch)),
            findsNothing,
          );
          expect(
            find.descendant(of: _card(id), matching: find.byType(DeskButton)),
            findsNothing,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final width in [360.0, 420.0]) {
    testWidgets(
      'catalog and attendance segment text stays inside at $width width and double scale',
      (tester) async {
        final native = _Native(includeAttendance: true);
        native.installed.add('attendance');
        native.enabled.add('attendance');
        native.configs['attendance'] = {'mode': 'fixed', 'automatic': false};
        await _mount(tester, native, width: width, scale: 2);
        final catalog = find.byWidgetPredicate(
          (widget) =>
              widget is GlassSegmentedControl &&
              widget.segments.first.label == '已安装 4',
        );
        expect(MediaQuery.textScalerOf(tester.element(catalog)).scale(13), 26);
        _expectSegmentLabelsInside(tester, catalog, ['已安装 4', '全部扩展 5']);
        expect(_card('value'), findsNothing);
        await _all(tester);
        _expectSegmentLabelsInside(tester, catalog, ['已安装 4', '全部扩展 5']);
        expect(tester.widget<GlassSegmentedControl>(catalog).selectedIndex, 1);
        expect(_card('value'), findsOneWidget);

        await _open(tester, 'attendance');
        final attendance = find.byWidgetPredicate(
          (widget) =>
              widget is GlassSegmentedControl &&
              widget.segments.first.label == '固定签到',
        );
        await tester.ensureVisible(attendance);
        await _frames(tester);
        _expectSegmentLabelsInside(tester, attendance, ['固定签到', '运气签到']);
        await tester.tap(find.text('运气签到'));
        await _frames(tester);
        _expectSegmentLabelsInside(tester, attendance, ['固定签到', '运气签到']);
        expect(
          tester.widget<GlassSegmentedControl>(attendance).selectedIndex,
          1,
        );
        expect(native.named('extensions.configure').single.$2, {
          'id': 'attendance',
          'settings': {'mode': 'random'},
        });
        expect(native.named('attendance.perform'), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('short narrow details retain reachable controls with 1.6 text', (
    tester,
  ) async {
    final native = _Native()..installed = _titles.keys.toSet();
    await _mount(tester, native, width: 360, height: 540, scale: 1.6);
    for (final id in _titles.keys) {
      await _open(tester, id);
      await tester.ensureVisible(_button('移除扩展'));
      await _frames(tester);
      expect(_button('移除扩展').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(_button('扩展中心'));
      await _frames(tester);
    }
    expect(native.named('extensions.configure'), isEmpty);
    expect(native.named('extensions.acknowledgeHits'), isEmpty);
  });

  testWidgets(
    'filter counts and empty installed catalog preserve selection on return',
    (tester) async {
      final native = _Native()..installed = {};
      await _mount(tester, native);
      expect(find.text('已安装 0'), findsOneWidget);
      expect(find.text('全部扩展 4'), findsOneWidget);
      expect(find.text('还没有已安装的扩展'), findsOneWidget);
      await tester.tap(_button('浏览全部扩展'));
      await _frames(tester);
      expect(_card('office'), findsOneWidget);
      await _open(tester, 'office');
      expect(find.text('功能预览'), findsOneWidget);
      expect(find.byType(CupertinoTextField), findsNothing);
      await tester.tap(_button('扩展中心'));
      await _frames(tester);
      expect(_card('value'), findsOneWidget);
      expect(native.named('extensions.install'), isEmpty);
    },
  );

  testWidgets(
    'whole card keyboard navigation and enable switch issue one action',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final native = _Native();
        await _mount(tester, native);
        final cardNode = tester.getSemantics(_card('hot'));
        final node = cardNode.getSemanticsData();
        expect(node.label, 'NodeSeek 热榜，已启用，查看详情');
        expect(node.hint, 'Local extension fixture description');
        expect(node.flagsCollection.isButton, isTrue);
        expect(node.hasAction(SemanticsAction.tap), isTrue);
        var childCount = 0;
        cardNode.visitChildren((_) {
          childCount++;
          return true;
        });
        expect(childCount, 0, reason: 'The card exposes one navigation action');
        final focus = tester
            .widget<FocusableActionDetector>(
              find.descendant(
                of: _card('hot'),
                matching: find.byType(FocusableActionDetector),
              ),
            )
            .focusNode!;
        focus.requestFocus();
        await _frames(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _frames(tester);
        expect(find.text('浏览热榜'), findsOneWidget);
        final toggle = find.byWidgetPredicate(
          (widget) =>
              widget is GlassSwitch &&
              widget.semanticLabel == '启用NodeSeek 热榜扩展',
        );
        final callback = tester.widget<GlassSwitch>(toggle).onChanged;
        native.pendingEnable = Completer<JsonMap>();
        callback(false);
        callback(false);
        await _frames(tester);
        expect(native.named('extensions.setEnabled'), hasLength(1));
        expect(native.named('extensions.setEnabled').single.$2, {
          'id': 'hot',
          'enabled': false,
        });
        native.enabled.remove('hot');
        native.pendingEnable!.complete(native.snapshot);
        await _frames(tester);
        expect(tester.widget<GlassSwitch>(toggle).value, isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'office reflow preserves controller composing selection focus and field state',
    (tester) async {
      final width = ValueNotifier(900.0);
      addTearDown(width.dispose);
      final native = _Native();
      await _mount(tester, native, liveWidth: width);
      await _open(tester, 'office');
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is CupertinoTextField && widget.placeholder == '伪装窗口标题',
      );
      final controller = tester.widget<CupertinoTextField>(field).controller!;
      final fieldState = tester.state(field);
      await tester.tap(field);
      await _frames(tester);
      controller.value = const TextEditingValue(
        text: '尚未保存的输入',
        selection: TextSelection.collapsed(offset: 7),
        composing: TextRange(start: 0, end: 7),
      );
      final editing = controller.value;
      final focus = FocusManager.instance.primaryFocus;
      for (final target in [840.0, 900.0]) {
        width.value = target;
        await _frames(tester);
        expect(tester.state(field), same(fieldState));
        expect(
          tester.widget<CupertinoTextField>(field).controller,
          same(controller),
        );
        expect(controller.value, editing);
        expect(FocusManager.instance.primaryFocus, same(focus));
        expect(field.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      expect(native.named('extensions.configure'), isEmpty);
      await tester.ensureVisible(_button('保存设置'));
      await tester.tap(_button('保存设置'));
      await _frames(tester);
      expect(native.named('extensions.configure').single.$2['settings'], {
        'title': editing.text,
        'button': '工作表',
        'key': '9',
      });
    },
  );

  testWidgets(
    'failed installation retains preview and retries without changing the filter',
    (tester) async {
      final native = _Native()..failInstall = true;
      await _mount(tester, native);
      await _all(tester);
      await _open(tester, 'value');
      await tester.tap(_button('添加扩展'));
      await _frames(tester);
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('安装未成功，请重试。'), findsOneWidget);
      expect(find.text('功能预览'), findsOneWidget);
      expect(_button('试算'), findsNothing);
      native.failInstall = false;
      await tester.tap(_button('添加扩展'));
      await _frames(tester);
      expect(_button('试算'), findsOneWidget);
      expect(native.named('extensions.install'), hasLength(2));
      await tester.tap(_button('试算'));
      await _frames(tester);
      expect(find.byType(ValueScreen), findsOneWidget);
    },
  );

  testWidgets(
    'account revision retires pending detail operation and old form contents',
    (tester) async {
      final native = _Native();
      final state = await _mount(tester, native);
      await _open(tester, 'office');
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is CupertinoTextField && widget.placeholder == '伪装窗口标题',
      );
      await tester.enterText(field, 'Previous account unsaved input');
      final toggle = tester.widget<GlassSwitch>(
        find.byWidgetPredicate(
          (widget) =>
              widget is GlassSwitch && widget.semanticLabel == '启用摸鱼老板键扩展',
        ),
      );
      native.pendingEnable = Completer<JsonMap>();
      toggle.onChanged(false);
      await _frames(tester);
      native.accessRevision++;
      state.showMessage('Fixture account changed');
      await _frames(tester);
      expect(find.byType(CupertinoTextField), findsNothing);
      native.pendingEnable!.complete(native.snapshot);
      await _frames(tester);
      expect(find.text('Previous account unsaved input'), findsNothing);
      expect(native.named('extensions.configure'), isEmpty);
      await _open(tester, 'office');
      expect(
        tester.widget<CupertinoTextField>(field).controller!.text,
        'Fixture sheet',
      );
    },
  );

  testWidgets(
    'keyword detail lists beyond popup limit and marks read only explicitly',
    (tester) async {
      final native = _Native();
      await _mount(tester, native);
      await _open(tester, 'keywords');
      expect(find.text('Runtime keyword match 11'), findsOneWidget);
      expect(find.textContaining('最多 25 组'), findsOneWidget);
      expect(find.textContaining('最近检查'), findsOneWidget);
      expect(native.named('extensions.acknowledgeHits'), isEmpty);
      await tester.ensureVisible(_button('全部标为已读'));
      await tester.tap(_button('全部标为已读'));
      await _frames(tester);
      expect(native.named('extensions.acknowledgeHits'), hasLength(1));
      expect(find.text('未读 0 条'), findsOneWidget);
      expect(tester.widget<DeskButton>(_button('全部标为已读')).onTap, isNull);
      final hit = find.byKey(const ValueKey('extension-hit-5011'));
      await tester.ensureVisible(hit);
      await tester.tap(hit);
      await _frames(tester);
      expect(native.named('reader.open').single.$2['id'], '5011');
    },
  );

  testWidgets(
    'hot details delegate one navigation without fetching a second ranking cache',
    (tester) async {
      final native = _Native();
      var openings = 0;
      await _mount(tester, native, rankings: () => openings++);
      await _open(tester, 'hot');
      await tester.tap(_button('打开热榜'));
      await _frames(tester);
      expect(openings, 1);
      expect(find.text('原作者 @小号'), findsOneWidget);
      expect(find.text('原热榜项目'), findsOneWidget);
      expect(native.named('rankings.load'), isEmpty);
    },
  );

  testWidgets(
    'native parsed empty keyword terms do not claim monitoring is running',
    (tester) async {
      final native = _Native();
      native.configs['keywords'] = {
        ...jsonMap(native.configs['keywords']),
        'words': '+',
        'terms': <String>[],
      };
      await _mount(tester, native);
      await _open(tester, 'keywords');
      expect(find.text('添加关键词后开始监控'), findsOneWidget);
      expect(find.textContaining('最近检查'), findsNothing);
      expect(find.text('正在检查新帖…'), findsNothing);
      expect(native.named('extensions.acknowledgeHits'), isEmpty);
    },
  );
}
