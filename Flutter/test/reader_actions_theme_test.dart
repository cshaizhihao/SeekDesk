// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' as material;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/desk_material_scope.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/reader_context.dart';

const _management = ValueKey('reader-actions-management');
const _block = ValueKey('reader-actions-block');
const _edit = ValueKey('reader-actions-edit');
const _body = ValueKey('reader-actions-body');
const _date = '2026-11-15 09:37';
const _keys = [_management, _block, _edit];

class _LocalNative extends NativeClient {
  _LocalNative()
    : super(methods: const MethodChannel('seekdesk.test.reader-actions-theme'));
  final calls = <String>[];

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add(method);
    throw StateError(
      'Reader action theme checks cannot invoke native operations: $method',
    );
  }
}

class _Harness extends StatefulWidget {
  const _Harness({required this.appState, this.sdkBaseline = false, super.key});
  final AppState appState;
  final bool sdkBaseline;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  double width = 760, textScale = 1;
  int revision = 0;
  bool showBlock = true, showActions = true;
  Brightness brightness = Brightness.light;
  Color primary = const Color(0xff3b6f92);
  material.ThemeData? inheritedMaterial, expectedTheme;
  final activated = <String>[];

  void update(VoidCallback change) => setState(change);

  @override
  Widget build(BuildContext context) {
    // Capture a render-specific value so callback tests detect an old closure.
    final currentRevision = revision;
    Widget action(Key key, String label, IconData icon) => _RetainedAction(
      key: key,
      label: label,
      icon: icon,
      onActivated: () => activated.add('$label@$currentRevision'),
    );
    return CupertinoApp(
      theme: CupertinoThemeData(brightness: brightness, primaryColor: primary),
      home: Builder(
        builder: (context) {
          final content = Builder(
            builder: (context) {
              // Only value-comparison tests query the SDK fallback outside the
              // scope. Extra fallbacks would pollute its tiny localization cache
              // when checking identity reuse across ordinary parent rebuilds.
              expectedTheme = widget.sdkBaseline
                  ? material.Theme.of(context)
                  : null;
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(textScale),
                  disableAnimations: true,
                ),
                child: GlassAdaptiveScope(
                  minQuality: GlassQuality.minimal,
                  maxQuality: GlassQuality.minimal,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: width,
                      child: ReaderFloorContext(
                        state: widget.appState,
                        topic: TopicData({
                          'id': '3701',
                          'url': 'https://www.nodeseek.com/post-3701-1',
                          'title': 'Local reader action theme fixture',
                        }),
                        floor: FloorData({
                          'id': '3',
                          'authorID': 73,
                          'author': 'Alice',
                          'date': _date,
                          'avatar': '',
                        }),
                        root: false,
                        authorScale: 1,
                        profilesSupported: false,
                        actions: [
                          if (showActions) ...[
                            action(_management, '管理记录', CupertinoIcons.shield),
                            if (showBlock)
                              action(
                                _block,
                                '屏蔽作者',
                                CupertinoIcons.person_crop_circle_badge_xmark,
                              ),
                            action(_edit, '编辑楼层', CupertinoIcons.pencil),
                          ],
                        ],
                        body: const _RetainedBody(key: _body),
                      ),
                    ),
                  ),
                ),
              );
            },
          );
          if (inheritedMaterial case final theme?) {
            return material.Theme(data: theme, child: content);
          }
          return content;
        },
      ),
    );
  }
}

// Local keys preserve sibling identity but cannot independently move these
// states across parents. That requires the production group's retained root.
class _RetainedAction extends StatefulWidget {
  const _RetainedAction({
    required this.label,
    required this.icon,
    required this.onActivated,
    super.key,
  });
  final String label;
  final IconData icon;
  final VoidCallback onActivated;

  @override
  State<_RetainedAction> createState() => _RetainedActionState();
}

class _RetainedActionState extends State<_RetainedAction> {
  int activations = 0;

  @override
  Widget build(BuildContext context) => DeskIcon(widget.label, widget.icon, () {
    setState(() => activations++);
    widget.onActivated();
  });
}

class _RetainedBody extends StatefulWidget {
  const _RetainedBody({super.key});

  @override
  State<_RetainedBody> createState() => _RetainedBodyState();
}

class _RetainedBodyState extends State<_RetainedBody> {
  String marker = 'Original body';
  void remember() => setState(() => marker = 'Retained reading marker');

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 80,
    child: Text(
      marker,
      style: TextStyle(color: CupertinoTheme.of(context).primaryColor),
    ),
  );
}

Finder _action(Key key) =>
    find.descendant(of: find.byKey(key), matching: find.byType(DeskIcon));
Finder _tooltip(Key key) => find.descendant(
  of: find.byKey(key),
  matching: find.byType(material.Tooltip),
);
Finder get _scope => find.descendant(
  of: find.byType(ReaderFloorContext),
  matching: find.byType(DeskMaterialScope),
);

material.ThemeData _expectShared(
  WidgetTester tester, {
  List<Key> keys = _keys,
}) {
  final themes = [
    for (final key in keys) material.Theme.of(tester.element(_tooltip(key))),
  ];
  for (final theme in themes) {
    expect(theme, same(themes.first));
  }
  return themes.first;
}

FocusNode _focusAction(WidgetTester tester, Key key) {
  final glyph = find.descendant(of: _action(key), matching: find.byType(Icon));
  final focus = Focus.of(tester.element(glyph));
  focus.requestFocus();
  return focus;
}

Future<void> _frames(WidgetTester tester) async {
  for (var index = 0; index < 4; index++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<_HarnessState> _mount(
  WidgetTester tester, {
  bool sdkBaseline = false,
}) async {
  final native = _LocalNative();
  final appState = AppState(client: native)..connecting = false;
  final key = GlobalKey<_HarnessState>();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    appState.dispose();
    expect(native.calls, isEmpty);
  });
  await tester.pumpWidget(
    _Harness(key: key, appState: appState, sdkBaseline: sdkBaseline),
  );
  await _frames(tester);
  return key.currentState!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'only action tooltips share a theme and ordinary parent refreshes reuse it',
    (tester) async {
      final host = await _mount(tester);
      expect(_scope, findsOneWidget);
      final theme = _expectShared(tester);
      final scope = tester.state(_scope);
      for (final key in _keys) {
        expect(
          find.ancestor(of: _tooltip(key), matching: _scope),
          findsOneWidget,
        );
      }
      for (final outside in [
        find.byKey(_body),
        find.text('Alice'),
        find.text(_date),
      ]) {
        expect(
          find.ancestor(of: outside, matching: find.byType(DeskMaterialScope)),
          findsNothing,
        );
      }
      for (var revision = 1; revision <= 4; revision++) {
        host.update(() => host.revision = revision);
        await tester.pump();
        expect(tester.state(_scope), same(scope));
        expect(_expectShared(tester), same(theme));
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'action themes follow day/night colors and inherited Material overrides',
    (tester) async {
      final host = await _mount(tester, sdkBaseline: true);
      for (final (brightness, primary) in [
        (Brightness.light, const Color(0xff327858)),
        (Brightness.dark, const Color(0xffb58151)),
      ]) {
        host.update(() {
          host.brightness = brightness;
          host.primary = primary;
        });
        await _frames(tester);
        final theme = _expectShared(tester);
        expect(theme, host.expectedTheme);
        expect(theme.brightness, brightness);
        expect(theme.colorScheme.primary, primary);
      }
      for (final (color, platform) in [
        (const Color(0xff6d538b), TargetPlatform.macOS),
        (const Color(0xff316c85), TargetPlatform.windows),
      ]) {
        host.update(
          () => host.inheritedMaterial = material.ThemeData(
            platform: platform,
            colorScheme: material.ColorScheme.fromSeed(
              seedColor: color,
              primary: color,
            ),
            tooltipTheme: const material.TooltipThemeData(
              textStyle: TextStyle(fontSize: 18, color: Color(0xffeef7f0)),
            ),
          ),
        );
        await _frames(tester);
        final theme = _expectShared(tester);
        // Theme.of localizes again inside the scope. Require equal values, not
        // identity with the separate SDK query above it.
        expect(theme, host.expectedTheme);
        expect(theme.colorScheme.primary, color);
        expect(theme.platform, platform);
        expect(theme.tooltipTheme.textStyle!.fontSize, 18);
        expect(
          find.ancestor(of: find.byKey(_body), matching: _scope),
          findsNothing,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the scope root and focused action survive narrow and large-text reparenting',
    (tester) async {
      final host = await _mount(tester);
      final scope = tester.state(_scope);
      final actions = {
        for (final key in _keys)
          key: tester.state<_RetainedActionState>(find.byKey(key)),
      };
      final body = tester.state<_RetainedBodyState>(find.byKey(_body))
        ..remember();
      final focus = _focusAction(tester, _edit);
      await tester.pump();
      expect(focus.hasPrimaryFocus, isTrue);
      for (final (width, scale, compact) in [
        (340.0, 1.0, true),
        (760.0, 1.0, false),
        (480.0, 1.0, false),
        (480.0, 2.0, true),
        (760.0, 2.0, false),
        (760.0, 1.0, false),
      ]) {
        host.update(() {
          host.width = width;
          host.textScale = scale;
        });
        await _frames(tester);
        expect(tester.state(_scope), same(scope));
        expect(FocusManager.instance.primaryFocus, same(focus));
        expect(focus.hasPrimaryFocus, isTrue);
        expect(tester.state(find.byKey(_body)), same(body));
        expect(find.text('Retained reading marker'), findsOneWidget);
        for (final key in _keys) {
          expect(tester.state(find.byKey(key)), same(actions[key]));
          expect(_action(key).hitTestable(), findsOneWidget);
        }
        // Ensure the fixture actually crosses both production layout branches.
        final actionTop = tester.getTopLeft(_action(_edit)).dy;
        final dateBottom = tester.getBottomLeft(find.text(_date)).dy;
        expect(actionTop >= dateBottom, compact);
        // Reparenting may refresh inherited dependencies; all consumers must
        // still share the current theme, without requiring the old theme object.
        _expectShared(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await _frames(tester);
        expect(host.activated.last, '编辑楼层@0');
      }
      expect(actions[_edit]!.activations, 6);
      expect(host.activated, List.filled(6, '编辑楼层@0'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'conditional actions preserve surviving focus/state and use the newest callbacks',
    (tester) async {
      final host = await _mount(tester);
      final scope = tester.state(_scope);
      final management = tester.state<_RetainedActionState>(
        find.byKey(_management),
      );
      final removed = tester.state<_RetainedActionState>(find.byKey(_block));
      final edit = tester.state<_RetainedActionState>(find.byKey(_edit));
      final body = tester.state(find.byKey(_body));
      await tester.tap(_action(_management));
      await _frames(tester);
      expect(host.activated, ['管理记录@0']);
      final focus = _focusAction(tester, _edit);
      await tester.pump();
      host.update(() {
        host.revision = 1;
        host.showBlock = false;
        host.width = 340;
      });
      await _frames(tester);
      expect(find.byKey(_block), findsNothing);
      expect(removed.mounted, isFalse);
      expect(tester.state(_scope), same(scope));
      expect(tester.state(find.byKey(_management)), same(management));
      expect(tester.state(find.byKey(_edit)), same(edit));
      expect(FocusManager.instance.primaryFocus, same(focus));
      _expectShared(tester, keys: [_management, _edit]);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _frames(tester);
      expect(host.activated.last, '编辑楼层@1');
      await tester.tap(_action(_management));
      await _frames(tester);
      expect(host.activated.last, '管理记录@1');

      host.update(() {
        host.showBlock = true;
        host.revision = 2;
      });
      await _frames(tester);
      expect(tester.state(find.byKey(_block)), isNot(same(removed)));
      expect(tester.state(find.byKey(_edit)), same(edit));
      expect(management.activations, 2);
      expect(edit.activations, 1);
      _expectShared(tester);
      await tester.tap(_action(_block));
      await _frames(tester);
      expect(host.activated.last, '屏蔽作者@2');
      host.update(() => host.showActions = false);
      await _frames(tester);
      expect(_scope, findsNothing);
      expect(find.byType(DeskIcon), findsNothing);
      expect(tester.state(find.byKey(_body)), same(body));
      expect(tester.takeException(), isNull);
    },
  );
}
