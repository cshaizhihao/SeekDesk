import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/core/native_composer_drop.dart';
import 'package:seekdesk_flutter/widgets/composer_paste_scope.dart';
import 'package:seekdesk_flutter/widgets/document_history_scope.dart';

import 'support/composer_drop_fixture.dart';

const _channel = MethodChannel('cc.seekdesk/composer.drop.v1');
const _bodyKey = ValueKey('drop-body');

class _DropScopeFixture {
  final editor = DropEditor();
  final navigator = GlobalKey<NavigatorState>();
  final change = ValueNotifier(0);
  bool enabled = true, markdown = true, visible = true, covered = false;
  double width = 520;
  var bodyBuilds = 0;

  Widget get widget => CupertinoApp(
    navigatorKey: navigator,
    builder: (context, child) => GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: child!,
    ),
    home: CupertinoPageScaffold(
      child: Center(
        child: ValueListenableBuilder(
          valueListenable: change,
          builder: (context, _, child) => SizedBox(
            width: width,
            height: 170,
            child: Stack(
              fit: StackFit.expand,
              children: [
                TickerMode(
                  enabled: visible,
                  child: ComposerPasteScope(
                    media: editor.media,
                    bodyFocus: editor.focus,
                    enabled: enabled,
                    imageDropEnabled: markdown,
                    requestKey: () async => null,
                    child: child!,
                  ),
                ),
                if (covered) const ColoredBox(color: Color(0xffeeeeee)),
              ],
            ),
          ),
          child: Builder(
            builder: (context) {
              bodyBuilds++;
              return DocumentHistoryScope(
                history: editor.history,
                child: CupertinoTextField(
                  key: _bodyKey,
                  controller: editor.content,
                  focusNode: editor.focus,
                  selectAllOnFocus: false,
                  minLines: null,
                  maxLines: null,
                  expands: true,
                  contextMenuBuilder: ComposerPasteScope.contextMenuBuilder,
                ),
              );
            },
          ),
        ),
      ),
    ),
  );

  void rebuild() => change.value++;
  void dispose() {
    editor.dispose();
    change.dispose();
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final targets = <JsonMap>[];
  var clipboardReads = 0;

  setUp(() {
    NativeComposerDrop.instance.dispose();
    targets.clear();
    clipboardReads = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
      call,
    ) async {
      expect(call.method, 'updateTarget');
      targets.add(jsonMap(call.arguments));
      return null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') clipboardReads++;
        if (call.method == 'Clipboard.hasStrings') return {'value': false};
        return null;
      },
    );
  });

  tearDown(() {
    NativeComposerDrop.instance.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  Future<void> mount(WidgetTester tester, _DropScopeFixture fixture) async {
    await tester.binding.setSurfaceSize(const Size(700, 500));
    await tester.pumpWidget(fixture.widget);
    await tester.pumpAndSettle();
    expect(targets.last['enabled'], true);
    expect(fixture.editor.focus.hasFocus, false);
  }

  Future<void> cleanup(WidgetTester tester, _DropScopeFixture fixture) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    fixture.dispose();
    await tester.binding.setSurfaceSize(null);
    expect(tester.takeException(), isNull);
    expect(clipboardReads, 0);
  }

  Future<bool> event(
    WidgetTester tester,
    JsonMap target, {
    String phase = 'enter',
    String? token,
    Offset? position,
  }) async {
    final point =
        position ??
        Offset(
          (target['left'] as num).toDouble() + 36,
          (target['top'] as num).toDouble() + 18,
        );
    final response = binding.defaultBinaryMessenger.handlePlatformMessage(
      _channel.name,
      _channel.codec.encodeMethodCall(
        MethodCall('drag', {
          'phase': phase,
          'documentID': target['documentID'],
          'accessRevision': target['accessRevision'],
          'targetRevision': target['targetRevision'],
          'x': point.dx,
          'y': point.dy,
          'dropToken': ?token,
        }),
      ),
      null,
    );
    await tester.pump();
    final bytes = await response;
    return _channel.codec.decodeEnvelope(bytes!) == true;
  }

  testWidgets(
    'an unfocused editor accepts hover without rebuilding its body or publishing unchanged geometry',
    (tester) async {
      final f = _DropScopeFixture();
      await mount(tester, f);
      final target = targets.last;
      final rect = tester.getRect(find.byKey(_bodyKey));
      expect(target['left'], rect.left);
      expect(target['top'], rect.top);
      expect(target['width'], rect.width);
      expect(target['height'], rect.height);
      final builds = f.bodyBuilds, publications = targets.length;
      expect(await event(tester, target), true);
      expect(find.text('松开以上传图片'), findsOneWidget);
      expect(f.bodyBuilds, builds);
      f.editor.content.value = const TextEditingValue(
        text: 'ordinary typing',
        selection: TextSelection.collapsed(offset: 15),
      );
      await tester.pump();
      expect(targets, hasLength(publications));
      expect(f.bodyBuilds, builds);
      expect(await event(tester, target, phase: 'exit'), true);
      expect(find.text('松开以上传图片'), findsNothing);
      expect(tester.binding.hasScheduledFrame, false);
      await cleanup(tester, f);
    },
  );

  testWidgets(
    'dropping into the actual paste scope uploads once at the pointed caret and remains undoable',
    (tester) async {
      final f = _DropScopeFixture();
      f.editor.native.uploadGate = Completer<JsonMap>();
      await mount(tester, f);
      final target = targets.last, original = f.editor.content.text;
      expect(
        await event(tester, target, phase: 'drop', token: 'valid-drop'),
        true,
      );
      await tester.pump();
      expect(f.editor.focus.hasFocus, true);
      expect(f.editor.media.busy, true);
      expect(
        f.editor.native.arguments('system.captureComposerDrop'),
        hasLength(1),
      );
      expect(f.editor.native.arguments('system.captureComposerPaste'), isEmpty);
      expect(targets.last['enabled'], false);
      final caret = f.editor.content.selection.extentOffset;
      f.editor.native.uploadGate!.complete({'markdown': droppedMarkdown});
      await tester.pump();
      await tester.pump();
      expect(
        f.editor.content.text,
        original.replaceRange(caret, caret, droppedMarkdown),
      );
      expect(f.editor.applied, 1);
      expect(
        f.editor.native.arguments('images.releaseClipboardSnapshot'),
        hasLength(1),
      );
      expect(
        f.editor.native.arguments('system.releaseComposerDrop'),
        hasLength(1),
      );
      expect(f.editor.history.undo(), true);
      expect(f.editor.content.text, original);
      await cleanup(tester, f);
    },
  );

  testWidgets(
    'resizing retires old coordinates and a visual overlay rejects a covered editor',
    (tester) async {
      final f = _DropScopeFixture();
      await mount(tester, f);
      final old = targets.last;
      f.width = 230;
      f.rebuild();
      await tester.pump();
      final current = targets.last;
      expect(current['targetRevision'], isNot(old['targetRevision']));
      expect(
        await event(tester, old, phase: 'drop', token: 'stale-layout'),
        false,
      );
      expect(await event(tester, current), true);
      expect(find.text('松开以上传图片'), findsOneWidget);
      f.covered = true;
      f.rebuild();
      await tester.pump();
      expect(
        await event(tester, current, phase: 'drop', token: 'covered-body'),
        false,
      );
      expect(find.text('松开以上传图片'), findsNothing);
      expect(f.editor.native.arguments('system.captureComposerDrop'), isEmpty);
      expect(
        f.editor.native.arguments('system.releaseComposerDrop'),
        hasLength(2),
      );
      await cleanup(tester, f);
    },
  );

  for (final kind in [
    'disabled',
    'plain-text',
    'hidden',
    'IME',
    'account',
    'office',
  ]) {
    testWidgets(
      '$kind retires the target and releases a late drop without capture',
      (tester) async {
        final f = _DropScopeFixture();
        await mount(tester, f);
        final target = targets.last;
        expect(await event(tester, target), true);
        switch (kind) {
          case 'disabled':
            f.enabled = false;
          case 'plain-text':
            f.markdown = false;
          case 'hidden':
            f.visible = false;
          case 'IME':
            f.editor.content.value = const TextEditingValue(
              text: '拼音',
              selection: TextSelection.collapsed(offset: 2),
              composing: TextRange(start: 0, end: 2),
            );
          case 'account':
            f.editor.native.accessRevision++;
          case 'office':
            f.editor.state.domains['extensions'] = {
              'items': [
                {'id': 'office', 'active': true},
              ],
              'settings': {
                'office': {'presented': true},
              },
            };
        }
        f.rebuild();
        await tester.pump();
        expect(targets.last['enabled'], false);
        expect(find.text('松开以上传图片'), findsNothing);
        expect(
          await event(tester, target, phase: 'drop', token: 'late-$kind'),
          false,
        );
        expect(
          f.editor.native.arguments('system.captureComposerDrop'),
          isEmpty,
        );
        expect(
          f.editor.native.arguments('system.releaseComposerDrop'),
          hasLength(1),
        );
        await cleanup(tester, f);
      },
    );
  }

  testWidgets(
    'a route ABA during native capture releases the snapshot without upload or insertion',
    (tester) async {
      final f = _DropScopeFixture();
      f.editor.native.captureGate = Completer<JsonMap>();
      await mount(tester, f);
      final original = f.editor.content.text;
      expect(
        await event(tester, targets.last, phase: 'drop', token: 'route-drop'),
        true,
      );
      unawaited(
        f.navigator.currentState!.push<void>(
          CupertinoPageRoute(
            builder: (_) => const CupertinoPageScaffold(
              child: Center(child: Text('Other page')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      f.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      f.editor.native.captureGate!.complete({...droppedSnapshot});
      await tester.pump();
      await tester.pump();
      expect(
        f.editor.native.arguments('images.uploadClipboardSnapshot'),
        isEmpty,
      );
      expect(
        f.editor.native.arguments('images.releaseClipboardSnapshot'),
        hasLength(1),
      );
      expect(
        f.editor.native.arguments('system.releaseComposerDrop'),
        hasLength(1),
      );
      expect(f.editor.content.text, original);
      expect(f.editor.media.busy, false);
      await cleanup(tester, f);
    },
  );

  testWidgets(
    'disposing a hovered editor retires its geometry and rejects a late host drop',
    (tester) async {
      final f = _DropScopeFixture();
      await mount(tester, f);
      final target = targets.last;
      expect(await event(tester, target), true);
      expect(find.text('松开以上传图片'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(targets.last['enabled'], false);
      expect(
        await event(tester, target, phase: 'drop', token: 'disposed-scope'),
        false,
      );
      expect(f.editor.native.arguments('system.captureComposerDrop'), isEmpty);
      expect(
        f.editor.native.arguments('system.releaseComposerDrop'),
        hasLength(1),
      );
      f.dispose();
      await tester.binding.setSurfaceSize(null);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tester.binding.hasScheduledFrame, false);
    },
  );
}
