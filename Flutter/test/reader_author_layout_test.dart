// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/reader_context.dart';

const _name = '非常长的作者姓名 LongUnbrokenAuthorNameForNarrowReadingColumns';
const _date = '2026-11-15 09:37:00 UTC+08:00';
const _tags = ['主题作者', '很长的论坛身份标签', 'AnotherLongCommunityRole'];
const _floorNumber = '#123456';
const _boundsKey = ValueKey('author-local-bounds');
const _managementKey = ValueKey('author-management-action');
const _blockKey = ValueKey('author-block-action');
const _bodyKey = ValueKey('author-reading-body');
const _topicURL = 'https://www.nodeseek.com/post-3701-1';

/// This fixture has no platform or network fallback. An unexpected request is
/// also recorded because a widget may catch the error while rendering.
class _AuthorNative extends NativeClient {
  _AuthorNative({this.profile})
    : super(methods: const MethodChannel('seekdesk.test.author-layout'));

  final calls = <String>[];
  final JsonMap? profile;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add(method);
    if (method == 'reader.author' &&
        profile != null &&
        arguments['id'] == 73 &&
        arguments['url'] == _topicURL) {
      return {'profile': profile, 'accessRevision': accessRevision};
    }
    throw StateError('Unexpected author layout operation: $method');
  }
}

class _AuthorHarness extends StatefulWidget {
  const _AuthorHarness({
    required this.state,
    required this.initialWidth,
    required this.authorScale,
    this.systemScale = 1,
    this.name = _name,
    this.floorId = '123456',
    this.tags = _tags,
    this.root = true,
    this.profilesSupported = false,
    super.key,
  });

  final AppState state;
  final double initialWidth, authorScale;
  final double systemScale;
  final String name, floorId;
  final List<String> tags;
  final bool root, profilesSupported;

  @override
  State<_AuthorHarness> createState() => _AuthorHarnessState();
}

class _AuthorHarnessState extends State<_AuthorHarness> {
  late double width = widget.initialWidth;
  final activated = <String>[];

  void resize(double value) => setState(() => width = value);

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: true,
      textScaler: TextScaler.linear(widget.systemScale),
    ),
    child: GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoPageScaffold(
        child: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            key: _boundsKey,
            width: width,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ReaderFloorContext(
                  state: widget.state,
                  topic: TopicData({
                    'id': '3701',
                    'url': _topicURL,
                    'title': 'Author geometry fixture',
                  }),
                  floor: FloorData({
                    'id': widget.floorId,
                    'authorID': 73,
                    'author': widget.name,
                    'avatar': '',
                    'date': _date,
                    'tags': widget.tags,
                  }),
                  root: widget.root,
                  authorScale: widget.authorScale,
                  profilesSupported: widget.profilesSupported,
                  actions: [
                    _RetainedAction(
                      key: _managementKey,
                      label: '管理记录',
                      icon: CupertinoIcons.shield,
                      onActivated: activated.add,
                    ),
                    _RetainedAction(
                      key: _blockKey,
                      label: '屏蔽作者',
                      icon: CupertinoIcons.person_crop_circle_badge_xmark,
                      onActivated: activated.add,
                    ),
                  ],
                  body: const _RetainedBody(key: _bodyKey),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Local keys intentionally cannot move these states between parents on their
/// own: the production action group's identity must preserve its descendants.
class _RetainedAction extends StatefulWidget {
  const _RetainedAction({
    required this.label,
    required this.icon,
    required this.onActivated,
    super.key,
  });

  final String label;
  final IconData icon;
  final ValueChanged<String> onActivated;

  @override
  State<_RetainedAction> createState() => _RetainedActionState();
}

class _RetainedActionState extends State<_RetainedAction> {
  int activations = 0;

  @override
  Widget build(BuildContext context) => DeskIcon(widget.label, widget.icon, () {
    activations++;
    widget.onActivated(widget.label);
  });
}

class _RetainedBody extends StatefulWidget {
  const _RetainedBody({super.key});

  @override
  State<_RetainedBody> createState() => _RetainedBodyState();
}

class _RetainedBodyState extends State<_RetainedBody> {
  String marker = 'Original reading body';

  void remember() => setState(() => marker = 'Retained reading position');

  @override
  Widget build(BuildContext context) =>
      SizedBox(width: double.infinity, height: 80, child: Text(marker));
}

Future<_AuthorHarnessState> _mount(
  WidgetTester tester, {
  required double width,
  required double scale,
  double systemScale = 1,
  String name = _name,
  String floorId = '123456',
  List<String> tags = _tags,
  bool root = true,
  JsonMap? profile,
}) async {
  await tester.binding.setSurfaceSize(const Size(1300, 2000));
  final native = _AuthorNative(profile: profile);
  final state = AppState(client: native)..connecting = false;
  if (profile != null) {
    state.readers[_topicURL] = {
      'url': _topicURL,
      'authorProfilesSupported': true,
      'thread': {
        'root': {'id': floorId, 'authorID': 73},
        'replies': <JsonMap>[],
      },
    };
  }
  final key = GlobalKey<_AuthorHarnessState>();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    state.dispose();
    await tester.binding.setSurfaceSize(null);
    expect(native.calls, profile == null ? isEmpty : ['reader.author']);
  });
  await tester.pumpWidget(
    CupertinoApp(
      home: _AuthorHarness(
        key: key,
        state: state,
        initialWidth: width,
        authorScale: scale,
        systemScale: systemScale,
        name: name,
        floorId: floorId,
        tags: tags,
        root: root,
        profilesSupported: profile != null,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return key.currentState!;
}

Finder _action(Key key) =>
    find.descendant(of: find.byKey(key), matching: find.byType(DeskIcon));

void _expectUsableGeometry(
  WidgetTester tester,
  double expectedWidth, {
  List<String> metadataText = const [
    _name,
    _date,
    _floorNumber,
    ..._tags,
    '楼主',
  ],
}) {
  final bounds = tester.getRect(find.byKey(_boundsKey));
  final body = tester.getRect(find.byKey(_bodyKey));
  expect(bounds.width, closeTo(expectedWidth, .01));
  expect(body.left, closeTo(bounds.left, .01));
  expect(body.right, closeTo(bounds.right, .01));

  final metadata = [
    for (final text in metadataText) tester.getRect(find.text(text)),
    tester.getRect(find.byType(NativeAvatar)),
  ];
  for (final rect in metadata) {
    expect(rect.left, greaterThanOrEqualTo(bounds.left - .01));
    expect(rect.right, lessThanOrEqualTo(bounds.right + .01));
    expect(rect.bottom, lessThanOrEqualTo(body.top));
  }

  final actions = <Rect>[];
  for (final key in [_managementKey, _blockKey]) {
    final target = _action(key);
    expect(target.hitTestable(), findsOneWidget);
    final rect = tester.getRect(target);
    expect(rect.left, greaterThanOrEqualTo(bounds.left - .01));
    expect(rect.right, lessThanOrEqualTo(bounds.right + .01));
    expect(rect.top, greaterThanOrEqualTo(bounds.top));
    expect(rect.bottom, lessThanOrEqualTo(body.top));
    expect(rect.overlaps(body), isFalse);
    for (final textOrAvatar in metadata) {
      expect(rect.overlaps(textOrAvatar), isFalse);
    }
    actions.add(rect);
  }
  expect(actions.first.overlaps(actions.last), isFalse);
  expect(tester.takeException(), isNull);
}

void _expectTextInside(WidgetTester tester, String text) {
  final finder = find.text(text);
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final textRect = tester.getRect(finder);
  final floorRect = tester.getRect(find.byKey(_boundsKey));
  final glyphs = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: text.length),
  );
  expect(glyphs, isNotEmpty, reason: text);
  expect(
    paragraph.didExceedMaxLines,
    isFalse,
    reason: '$text must remain readable.',
  );
  for (final glyph in glyphs) {
    final rect = glyph.toRect().shift(paragraph.localToGlobal(Offset.zero));
    expect(textRect.inflate(.5).contains(rect.topLeft), isTrue, reason: text);
    expect(
      textRect.inflate(.5).contains(rect.bottomRight),
      isTrue,
      reason: text,
    );
    expect(floorRect.inflate(.5).contains(rect.topLeft), isTrue, reason: text);
    expect(
      floorRect.inflate(.5).contains(rect.bottomRight),
      isTrue,
      reason: text,
    );
  }
}

void _expectFocusInside(WidgetTester tester, Key key) {
  final ancestor = tester.element(find.byKey(key));
  final context = FocusManager.instance.primaryFocus?.context;
  expect(context, isNotNull);
  var inside = identical(context, ancestor);
  context!.visitAncestorElements((element) {
    inside = inside || identical(element, ancestor);
    return !inside;
  });
  expect(inside, isTrue, reason: '$key must retain keyboard focus');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'short name rank and author role share a line above the complete date',
    (tester) async {
      await _mount(
        tester,
        width: 760,
        scale: 1,
        name: 'Alice',
        tags: const [],
        profile: {'member_id': 73, 'rank': 7},
      );
      final name = tester.getRect(find.text('Alice'));
      final rank = tester.getRect(find.text('Lv.7'));
      final role = tester.getRect(find.text('楼主'));
      final date = tester.getRect(find.text(_date));
      expect(name.right, lessThanOrEqualTo(rank.left));
      expect(name.top, lessThan(rank.bottom));
      expect(rank.top, lessThan(name.bottom));
      expect(role.top, lessThan(name.bottom));
      expect(name.top, lessThan(role.bottom));
      expect(date.left, closeTo(name.left, .1));
      expect(date.top, greaterThanOrEqualTo(name.bottom));
      expect(date.top, greaterThanOrEqualTo(rank.bottom));
      expect(date.top, greaterThanOrEqualTo(role.bottom));
      _expectUsableGeometry(
        tester,
        760,
        metadataText: const ['Alice', 'Lv.7', '楼主', _date, _floorNumber],
      );
      for (final text in ['Alice', 'Lv.7', '楼主', _date, _floorNumber]) {
        _expectTextInside(tester, text);
      }
    },
  );

  testWidgets(
    'unenriched short name has no empty metadata row before its date',
    (tester) async {
      await _mount(
        tester,
        width: 760,
        scale: 1,
        name: 'Alice',
        tags: const [],
        root: false,
      );
      final name = tester.getRect(find.text('Alice'));
      final date = tester.getRect(find.text(_date));
      expect(date.left, closeTo(name.left, .1));
      expect(date.top - name.bottom, inInclusiveRange(0, 8));
      expect(find.text('楼主'), findsNothing);
      expect(find.textContaining('Lv.'), findsNothing);
      _expectUsableGeometry(
        tester,
        760,
        metadataText: const ['Alice', _date, _floorNumber],
      );
      _expectTextInside(tester, _date);
    },
  );

  for (final width in [340.0, 520.0]) {
    for (final authorScale in [.75, 1.0, 1.6]) {
      for (final systemScale in [1.0, 2.0]) {
        testWidgets(
          'long author metadata stays legible at width $width author $authorScale system $systemScale',
          (tester) async {
            final harness = await _mount(
              tester,
              width: width,
              scale: authorScale,
              systemScale: systemScale,
              profile: {
                'member_id': 73,
                'rank': 12,
                'roles': [
                  {'display_text': '长期社区贡献者'},
                  {'display_text': 'ExtendedCommunityContributorRole'},
                ],
              },
            );
            const labels = [
              _name,
              _date,
              _floorNumber,
              ..._tags,
              '楼主',
              'Lv.12',
              '长期社区贡献者',
              'ExtendedCommunityContributorRole',
            ];
            _expectUsableGeometry(tester, width, metadataText: labels);
            for (final label in labels) {
              _expectTextInside(tester, label);
            }
            expect(
              tester.widget<Text>(find.text(_name)).style!.fontSize,
              greaterThanOrEqualTo(13 * authorScale),
            );
            expect(
              tester.widget<Text>(find.text(_date)).style!.fontSize,
              greaterThanOrEqualTo(11 * authorScale),
            );
            expect(
              MediaQuery.textScalerOf(tester.element(find.text(_name)))
                  .scale(14),
              14 * systemScale,
            );
            for (final key in [_managementKey, _blockKey]) {
              final target = _action(key);
              expect(tester.getSize(target).width, greaterThanOrEqualTo(32));
              expect(tester.getSize(target).height, greaterThanOrEqualTo(32));
              await tester.tap(target);
              await tester.pump();
            }
            expect(harness.activated, ['管理记录', '屏蔽作者']);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets(
    'twelve-digit floor wraps completely beside reachable actions at 340 and maximum text scales',
    (tester) async {
      const floorId = '123456789012';
      const floorLabel = '#$floorId';
      final harness = await _mount(
        tester,
        width: 340,
        scale: 1.6,
        systemScale: 2,
        floorId: floorId,
      );
      const labels = [_name, _date, floorLabel, ..._tags, '楼主'];
      _expectUsableGeometry(tester, 340, metadataText: labels);
      for (final label in labels) {
        _expectTextInside(tester, label);
      }
      final floor = find.text(floorLabel);
      final paragraph = tester.renderObject<RenderParagraph>(floor);
      final lines = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: floorLabel.length),
      );
      expect(lines.map((box) => box.top).toSet().length, greaterThan(1));
      expect(
        tester.widget<Text>(floor).style!.fontSize,
        closeTo(11 * 1.6, .01),
      );
      expect(MediaQuery.textScalerOf(tester.element(floor)).scale(14), 28);
      expect(
        tester.getRect(floor).top,
        greaterThanOrEqualTo(tester.getRect(find.text(_date)).bottom),
      );
      for (final key in [_managementKey, _blockKey]) {
        final target = _action(key);
        expect(tester.getSize(target).width, greaterThanOrEqualTo(32));
        expect(tester.getSize(target).height, greaterThanOrEqualTo(32));
        await tester.tap(target);
        await tester.pump();
      }
      expect(harness.activated, ['管理记录', '屏蔽作者']);
      expect(tester.takeException(), isNull);
    },
  );

  for (final (width, scale) in <(double, double)>[
    (419, 1),
    (420, 1),
    (519, 1.26),
    (520, 1.26),
  ]) {
    testWidgets(
      'local author width $width at scale $scale keeps both actions reachable',
      (tester) async {
        final harness = await _mount(tester, width: width, scale: scale);
        _expectUsableGeometry(tester, width);
        await tester.tap(_action(_managementKey));
        await tester.pump();
        expect(harness.activated, ['管理记录']);
        await tester.tap(_action(_blockKey));
        await tester.pump();
        expect(harness.activated, ['管理记录', '屏蔽作者']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final (wide, narrow, scale) in <(double, double, double)>[
    (420, 419, 1),
    (520, 519, 1.26),
  ]) {
    testWidgets(
      'resizing $wide to $narrow and back retains action focus and body state',
      (tester) async {
        final harness = await _mount(tester, width: wide, scale: scale);
        final management = tester.state<_RetainedActionState>(
          find.byKey(_managementKey),
        );
        final block = tester.state<_RetainedActionState>(find.byKey(_blockKey));
        final body = tester.state<_RetainedBodyState>(find.byKey(_bodyKey));
        body.remember();
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        _expectFocusInside(tester, _managementKey);
        final managementFocus = FocusManager.instance.primaryFocus;
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(harness.activated, ['管理记录']);
        expect(management.activations, 1);

        void expectRetainedChildren() {
          expect(tester.state(find.byKey(_managementKey)), same(management));
          expect(tester.state(find.byKey(_blockKey)), same(block));
          expect(tester.state(find.byKey(_bodyKey)), same(body));
          expect(body.marker, 'Retained reading position');
          expect(find.text('Retained reading position'), findsOneWidget);
        }

        harness.resize(narrow);
        await tester.pump();
        await tester.pump();
        expectRetainedChildren();
        expect(FocusManager.instance.primaryFocus, same(managementFocus));
        _expectFocusInside(tester, _managementKey);
        _expectUsableGeometry(tester, narrow);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(harness.activated, ['管理记录', '管理记录']);
        expect(management.activations, 2);

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        _expectFocusInside(tester, _blockKey);
        final blockFocus = FocusManager.instance.primaryFocus;
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(harness.activated, ['管理记录', '管理记录', '屏蔽作者']);
        expect(block.activations, 1);

        harness.resize(wide);
        await tester.pump();
        await tester.pump();
        expectRetainedChildren();
        expect(FocusManager.instance.primaryFocus, same(blockFocus));
        _expectFocusInside(tester, _blockKey);
        _expectUsableGeometry(tester, wide);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(harness.activated, ['管理记录', '管理记录', '屏蔽作者', '屏蔽作者']);
        expect(block.activations, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'large-text author actions and body retain focus and identity across a full reflow',
    (tester) async {
      final harness = await _mount(
        tester,
        width: 900,
        scale: 1.6,
        systemScale: 2,
      );
      final body = tester.state<_RetainedBodyState>(find.byKey(_bodyKey));
      final bodyElement = tester.element(find.byKey(_bodyKey));
      body.remember();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      _expectFocusInside(tester, _managementKey);
      final focus = FocusManager.instance.primaryFocus;
      final actionElement = tester.element(find.byKey(_managementKey));
      for (final width in [340.0, 900.0]) {
        harness.resize(width);
        await tester.pump();
        await tester.pump();
        expect(tester.element(find.byKey(_bodyKey)), same(bodyElement));
        expect(tester.state(find.byKey(_bodyKey)), same(body));
        expect(find.text('Retained reading position'), findsOneWidget);
        expect(tester.element(find.byKey(_managementKey)), same(actionElement));
        expect(FocusManager.instance.primaryFocus, same(focus));
        _expectFocusInside(tester, _managementKey);
        _expectUsableGeometry(tester, width);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
      }
      expect(harness.activated, ['管理记录', '管理记录']);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
