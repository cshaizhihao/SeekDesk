import 'dart:async';
import 'dart:convert';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/models/snapshots.dart';
import 'package:seekdesk_flutter/screens/composer_screen.dart';
import 'package:seekdesk_flutter/screens/reader_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/state/reader_editors.dart';
import 'package:seekdesk_flutter/widgets/forum_blocks.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/image_viewer_toolbar.dart';
import 'package:seekdesk_flutter/widgets/reader_editor_host.dart';

const _url = 'https://www.nodeseek.com/post-28401-1';
const _picture = 'https://media.example.invalid/reader.png';
const _nq = 'https://media.example.invalid/nq.png';
const _tq = 'https://media.example.invalid/tq.png';
const _after = 'The visible paragraph below the pending picture';
const _afterNq = 'Visible passage following the complete NQ long image';
const _afterTq = 'Visible passage following the TQ report';
const _draft = '保留在真实阅读页里的本地回复草稿';
final _wideContent = List.filled(30, 'visible horizontal content').join(' ');
const _topic = {
  'id': '28401',
  'url': _url,
  'title': 'Media reflow integration',
};

// Valid local PNGs: 160 × 100 and 160 × 900. Metadata matches encoded pixels;
// no Image.network, HTTP override, native channel or disk image is involved.
final _shortPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAKAAAABkCAYAAAABtjuPAAAA0ElEQVR42u3SQREAAAQAQZ100klaYnjYxxa4ucjqgSshAgbEgGBADAgGxIBgQAwIBsSAYEAMCAbEgGBADAgGxIBgQAwIBsSAYEAMCAbEgGBADAgGxIBgQAyIAYXAgBgQDIgBwYAYEAyIAcGAGBAMiAHBgBgQDIgBwYAYEAyIAcGAGBAMiAHBgBgQDIgBwYAYEAyIATEgGBADggExIBgQA4IBMSAYEAOCATEgGBADggExIBgQA4IBMSAYEAOCATEgGBADggExIBgQA2JAETAgXy2de/55AbQ4KgAAAABJRU5ErkJggg==',
);
final _longPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAKAAAAOECAYAAAAmGjqQAAAGUUlEQVR42u3SQREAAAQAQZ100klaYvDYxxa4ucjqgSshAgbEgGBADAgGxIBgQAwIBsSAYEAMCAbEgGBADAgGxIBgQAwIBsSAYEAMCAbEgGBADAgGxIBgQAyIAYXAgBgQDIgBwYAYEAyIAcGAGBAMiAHBgBgQDIgBwYAYEAyIAcGAGBAMiAHBgBgQDIgBwYAYEAyIATEgGBADggExIBgQA4IBMSAYEAOCATEgGBADggExIBgQA4IBMSAYEAOCATEgGBADggExIBgQA2JAETAgBgQDYkAwIAYEA2JAMCAGBANiQDAgBgQDYkAwIAYEA2JAMCAGBANiQDAgBgQDYkAwIAYEA2JADAgGxIBgQAwIBsSAYEAMCAbEgGBADAgGxIBgQAwIBsSAYEAMCAbEgGBADAgGxIBgQAwIBsSAYEAMiAHBgBgQDIgBwYAYEAyIAcGAGBAMiAHBgBgQDIgBwYAYEAyIAcGAGBAMiAHBgBgQDIgBwYAYEAOKgAExIBgQA4IBMSAYEAOCATEgGBADggExIBgQA4IBMSAYEAOCATEgGBADggExIBgQA4IBMSAYEANiQDAgBgQDYkAwIAYEA2JAMCAGBANiQDAgBgQDYkAwIAYEA2JAMCAGBANiQDAgBgQDYkAwIAbEgCJgQAwIBsSAYEAMCAbEgGBADAgGxIBgQAwIBsSAYEAMCAbEgGBADAgGxIBgQAwIBsSAYEAMCAbEgBhQCAyIAcGAGBAMiAHBgBgQDIgBwYAYEAyIAcGAGBAMiAHBgBgQDIgBwYAYEAyIAcGAGBAMiAHBgBgQA4IBMSAYEAOCATEgGBADggExIBgQA4IBMSAYEAOCATEgGBADggExIBgQA4IBMSAYEAOCATEgBhQBA2JAMCAGBANiQDAgBgQDYkAwIAYEA2JAMCAGBANiQDAgBgQDYkAwIAYEA2JAMCAGBANiQDAgBsSAYEAMCAbEgGBADAgGxIBgQAwIBsSAYEAMCAbEgGBADAgGxIBgQAwIBsSAYEAMCAbEgGBADAgGxIAYEAyIAcGAGBAMiAHBgBgQDIgBwYAYEAyIAcGAGBAMiAHBgBgQDIgBwYAYEAyIAcGAGBAMiAExoAgYEAOCATEgGBADggExIBgQA4IBMSAYEAOCATEgGBADggExIBgQA4IBMSAYEAOCATEgGBADggExIAYEA2JAMCAGBANiQDAgBgQDYkAwIAYEA2JAMCAGBANiQDAgBgQDYkAwIAYEA2JAMCAGBANiQAwoAgbEgGBADAgGxIBgQAwIBsSAYEAMCAbEgGBADAgGxIBgQAwIBsSAYEAMCAbEgGBADAgGxIBgQAyIAYXAgBgQDIgBwYAYEAyIAcGAGBAMiAHBgBgQDIgBwYAYEAyIAcGAGBAMiAHBgBgQDIgBwYAYEAyIATEgGBADggExIBgQA4IBMSAYEAOCATEgGBADggExIBgQA4IBMSAYEAOCATEgGBADggExIBgQA2JAETAgBgQDYkAwIAYEA2JAMCAGBANiQDAgBgQDYkAwIAYEA2JAMCAGBANiQDAgBgQDYkAwIAYEA2JADAgGxIBgQAwIBsSAYEAMCAbEgGBADAgGxIBgQAwIBsSAYEAMCAbEgGBADAgGxIBgQAwIBsSAYEAMiAHBgBgQDIgBwYAYEAyIAcGAGBAMiAHBgBgQDIgBwYAYEAyIAcGAGBAMiAHBgBgQDIgBwYAYEAOKgAExIBgQA4IBMSAYEAOCATEgGBADggExIBgQA4IBMSAYEAOCATEgGBADggExIBgQA4IBMSAYEANiQDAgBgQDYkAwIAYEA2JAMCAGBANiQDAgBgQDYkAwIAYEA2JAMCAGBANiQDAgBgQDYkAwIAbEgCJgQAwIBsSAYEAMCAbEgGBADAgGxIBgQAwIBsSAYEAMCAbEgGBADAgGxIBgQAwIBsSAYEAMCAbEgBhQCAyIAcGAGBAMiAHBgBgQDIgBwYAYEAyIAcGAGBAMiAHBgBgQDIgBwYAYEAyIAcGAGBAMiAHBgBgQA4IBMSAYEAOCATEgGBADggExIBgQA4IBMSAYEAOCATEgGBADggExIBgQA4IBMSAYEAOCATEgBhQBA2JAMCAGBANiQDAgBgQDYkAwIAYEA2JAMCAGBANiQDAgBgQDYkAwIAYEA2JAMCDfLOIM8rHgsdImAAAAAElFTkSuQmCC',
);

class _ImageRead {
  _ImageRead(this.url, this.kind);
  final String url, kind;
  final result = Completer<JsonMap>();
}

/// Only image reads/releases, local draft state, settings and position storage
/// are supported. Forum writes and all unplanned operations fail explicitly.
class _MediaNative extends NativeClient {
  _MediaNative({
    this.mediaFloor = 0,
    this.reports = false,
    this.restoredPosition,
    this.imageSize = const {},
    this.nestedList = false,
    this.horizontalBlock,
  }) : super(methods: const MethodChannel('seekdesk.test.reader-media-reflow'));

  final int mediaFloor;
  final bool reports;
  final JsonMap? restoredPosition;
  final JsonMap imageSize;
  final bool nestedList;
  final String? horizontalBlock;
  final reads = <_ImageRead>[];
  final saves = <JsonMap>[];
  final calls = <String>[];
  final unexpected = <String>[];
  String draft = _draft;
  final settings = <String, dynamic>{
    'workspace.readerTextSize': 15.0,
    'workspace.readingDensity': 'comfortable',
    'workspace.nqReportScale': 100.0,
    'workspace.tqReportScale': 100.0,
    'workspace.replySendKey': 'commandReturn',
  };

  JsonMap get draftSnapshot => {
    'topicID': '28401',
    'content': draft,
    'accessRevision': accessRevision,
    'imageURLs': <String>[],
    'imageSizing': <JsonMap>[],
  };

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add(method);
    if (method == 'images.load' &&
        const [_picture, _nq, _tq].contains(arguments['url']) &&
        const ['post', 'original'].contains(arguments['kind'])) {
      final read = _ImageRead(
        arguments['url'] as String,
        arguments['kind'] as String,
      );
      reads.add(read);
      return read.result.future;
    }
    if (method == 'images.release') return {'released': true};
    if (method == 'reader.rememberPosition' && arguments['url'] == _url) {
      saves.add({...arguments});
      return {'saved': true};
    }
    if (method == 'settings.update' &&
        const [
          'workspace.nqReportScale',
          'workspace.tqReportScale',
        ].contains(arguments['key'])) {
      settings[arguments['key'] as String] = arguments['value'];
      return {...settings};
    }
    if (method == 'reader.replyDraft' && arguments['topicID'] == '28401') {
      return draftSnapshot;
    }
    if (method == 'reader.updateReplyDraft' &&
        arguments['topicID'] == '28401') {
      draft = stringValue(arguments['content']);
      return draftSnapshot;
    }
    if (method == 'images.draftReferences') {
      return {
        'content': arguments['content'],
        'imageURLs': <String>[],
        'accessRevision': accessRevision,
      };
    }
    if (method == 'stickers.list') return {'packs': <JsonMap>[]};
    if (method == 'settings.get') return {...settings};
    unexpected.add(method);
    throw StateError('Unexpected media integration operation: $method');
  }

  void complete(String url, {String kind = 'post', bool tall = true}) {
    final read = reads.singleWhere(
      (read) =>
          read.url == url && read.kind == kind && !read.result.isCompleted,
    );
    read.result.complete({
      'bytes': tall ? _longPng : _shortPng,
      'width': 160,
      'height': tall ? 900 : 100,
      'originalWidth': 160,
      'originalHeight': tall ? 900 : 100,
    });
  }

  void fail(String url) {
    reads
        .singleWhere((read) => read.url == url && !read.result.isCompleted)
        .result
        .completeError(
          const NativeFailure('fixture_image', 'Memory image read failed'),
        );
  }

  List<JsonMap> get mediaBlocks => nestedList
      ? [
          {
            'kind': 'list',
            'items': [
              {
                'marker': '•',
                'blocks': [
                  {
                    'kind': 'list',
                    'items': [
                      {'marker': '3.', 'blocks': _mediaBlocks},
                    ],
                  },
                ],
              },
            ],
          },
        ]
      : _mediaBlocks;

  List<JsonMap> get _mediaBlocks => [
    for (var index = 0; index < 4; index++)
      {'kind': 'text', 'text': 'Paragraph above the media $index'},
    if (reports) ...[
      for (final report in [
        ('NQ 基本信息', _nq, _afterNq),
        ('TCP 测速', _tq, _afterTq),
      ]) ...[
        {
          'kind': 'tabs',
          'tabs': [
            {
              'label': report.$1,
              'blocks': [
                {'kind': 'image', 'url': report.$2},
              ],
            },
          ],
        },
        {'kind': 'text', 'text': report.$3},
        for (var line = 0; line < 5; line++)
          {'kind': 'text', 'text': '${report.$1} following paragraph $line'},
      ],
    ] else ...[
      {
        'kind': 'image',
        'url': _picture,
        'text': 'Local reader picture',
        'imageSize': imageSize,
      },
      {'kind': 'text', 'text': _after},
    ],
    for (var line = 0; line < 24; line++)
      {'kind': 'text', 'text': 'Long same-floor continuation $line'},
    if (horizontalBlock == 'code') {'kind': 'code', 'text': _wideContent},
    if (horizontalBlock == 'table')
      {
        'kind': 'table',
        'rows': [
          [_wideContent, 'Second column'],
          ['Value', 'Second value'],
        ],
      },
  ];

  JsonMap get snapshot => {
    'url': _url,
    'accessRevision': accessRevision,
    'scrollOffset': numberValue(restoredPosition?['offset']),
    if (restoredPosition?['bodyAnchor'] != null)
      'bodyAnchor': {...jsonMap(restoredPosition!['bodyAnchor'])},
    'loading': false,
    'authorProfilesSupported': false,
    'thread': {
      'title': _topic['title'],
      'category': '技术',
      'page': 1,
      'pages': <JsonMap>[],
      'root': {
        'id': '0',
        'author': 'Local root',
        'blocks': mediaFloor == 0
            ? mediaBlocks
            : [
                {'kind': 'text', 'text': 'Root before the long reply'},
              ],
      },
      'replies': [
        for (var floor = 1; floor <= 10; floor++)
          {
            'id': '$floor',
            'author': 'Local reply $floor',
            'blocks': floor == mediaFloor
                ? mediaBlocks
                : [
                    {'kind': 'text', 'text': 'Following reply $floor'},
                    {
                      'kind': 'text',
                      'text': 'More content keeps this fixture away from the bottom boundary.',
                    },
                  ],
          },
      ],
    },
  };
}

class _Host extends StatefulWidget {
  const _Host({required this.reader, required this.editors, super.key});
  final ReaderScreen reader;
  final ReaderEditors editors;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  double width = 760;
  double height = 820;
  void resizeWidth(double value) => setState(() => width = value);
  void resizeHeight(double value) => setState(() => height = value);

  @override
  Widget build(BuildContext context) => CupertinoApp(
    home: GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: GlassAccessibilityScope(
        reduceMotion: true,
        child: CupertinoPageScaffold(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: height,
              child: ReaderEditorHost(
                editors: widget.editors,
                child: widget.reader,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Finder get _reader => find.byType(ReaderScreen);
Finder get _scroll =>
    find.descendant(of: _reader, matching: find.byType(CustomScrollView));
Finder _text(String value) => find.text(value, findRichText: true);
Finder _image(String url) => find.byWidgetPredicate(
  (widget) => widget is NativeForumImage && widget.url == url,
);
Finder _decoded(String url) =>
    find.descendant(of: _image(url), matching: find.byType(Image));
Finder get _editorBody => find.byWidgetPredicate(
  (widget) => widget is CupertinoTextField && widget.expands,
);
Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder get _horizontalContent => find.ancestor(
  of: _text(_wideContent),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is SingleChildScrollView &&
        widget.scrollDirection == Axis.horizontal,
  ),
);

Future<void> _frames(WidgetTester tester, [int count = 8]) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

class _Fixture {
  _Fixture(
    this.native,
    this.state,
    this.host,
    WidgetTester tester,
    this._dispose,
  ) : controller = tester.widget<CustomScrollView>(_scroll).controller!,
      readerState = tester.state(_reader),
      readerElement = tester.element(_reader);
  final _MediaNative native;
  final AppState state;
  final GlobalKey<_HostState> host;
  final ScrollController controller;
  final Object readerState;
  final Element readerElement;
  final Future<void> Function() _dispose;

  Future<void> dispose() => _dispose();

  void expectRetained(WidgetTester tester) {
    expect(tester.state(_reader), same(readerState));
    expect(tester.element(_reader), same(readerElement));
    expect(
      tester.widget<CustomScrollView>(_scroll).controller,
      same(controller),
    );
    expect(tester.takeException(), isNull);
    expect(native.unexpected, isEmpty);
  }
}

Future<_Fixture> _mount(WidgetTester tester, {_MediaNative? native}) async {
  await tester.binding.setSurfaceSize(const Size(1100, 920));
  final client = native ?? _MediaNative();
  final state = AppState(client: client)..connecting = false;
  state.domains['workspace'] = {
    'tabs': [_topic],
    'selectedTab': '28401',
    'showReader': true,
  };
  state.domains['session'] = {
    'account': 'signedIn',
    'owner': 42,
    'canCompose': true,
  };
  state.domains['settings'] = {...client.settings};
  state.domains['extensions'] = {'items': <JsonMap>[]};
  state.readers[_url] = client.snapshot;
  final editors = ReaderEditors(
    state: state,
    readerVisible: () => true,
    canInteract: () => true,
    navigationIdentity: () => 0,
    revealTopic: (_) async {},
  );
  final key = GlobalKey<_HostState>();
  var disposed = false;
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    for (final read in client.reads) {
      if (!read.result.isCompleted) {
        read.result.complete({'bytes': _shortPng, 'width': 160, 'height': 100});
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    editors.dispose();
    state.dispose();
    await tester.pump();
    await tester.binding.setSurfaceSize(null);
    expect(client.unexpected, isEmpty);
  }

  addTearDown(dispose);
  await tester.pumpWidget(
    _Host(
      key: key,
      editors: editors,
      reader: ReaderScreen(
        state: state,
        topic: TopicData(_topic),
        editors: editors,
      ),
    ),
  );
  await _frames(tester);
  return _Fixture(client, state, key, tester, dispose);
}

Future<void> _place(
  WidgetTester tester,
  _Fixture fixture,
  Finder target, {
  double dy = 8,
}) async {
  for (var step = 0; target.evaluate().isEmpty && step < 40; step++) {
    fixture.controller.jumpTo(
      (fixture.controller.offset + 300).clamp(
        0.0,
        fixture.controller.position.maxScrollExtent,
      ),
    );
    await _frames(tester);
  }
  expect(target, findsOneWidget);
  for (var attempt = 0; attempt < 3; attempt++) {
    final relativeY =
        tester.getTopLeft(target).dy - tester.getTopLeft(_scroll).dy;
    fixture.controller.jumpTo(
      (fixture.controller.offset + relativeY - dy).clamp(
        0.0,
        fixture.controller.position.maxScrollExtent,
      ),
    );
    await _frames(tester);
  }
  expect(
    tester.getTopLeft(target).dy - tester.getTopLeft(_scroll).dy,
    closeTo(dy, 1),
  );
  expect(fixture.controller.offset, greaterThan(0));
  fixture.native.saves.clear();
}

Future<void> _expectSaved(WidgetTester tester, _Fixture fixture) async {
  await _frames(tester);
  await tester.pump(const Duration(milliseconds: 700));
  await _frames(tester);
  expect(fixture.native.saves, isNotEmpty);
  expect(
    fixture.native.saves.every((save) => numberValue(save['offset']) > 0),
    isTrue,
    reason: 'A media reflow must never persist an intermediate zero.',
  );
  expect(
    numberValue(fixture.native.saves.last['offset']),
    closeTo(fixture.controller.offset, 1),
  );
  fixture.expectRetained(tester);
}

Future<({_Fixture fixture, double savedY, double savedOffset})> _coldRoot(
  WidgetTester tester, {
  String? horizontalBlock,
}) async {
  final first = await _mount(
    tester,
    native: _MediaNative(horizontalBlock: horizontalBlock),
  );
  first.native.complete(_picture);
  await _frames(tester, 12);
  await _place(tester, first, _text(_after));
  await _expectSaved(tester, first);
  final savedY = tester.getTopLeft(_text(_after)).dy;
  final savedOffset = first.controller.offset;
  final saved = jsonMap(jsonDecode(jsonEncode(first.native.saves.last)));
  await first.dispose();
  final fixture = await _mount(
    tester,
    native: _MediaNative(
      restoredPosition: saved,
      horizontalBlock: horizontalBlock,
    ),
  );
  expect(fixture.state.imageDimensions(_picture), isEmpty);
  expect(fixture.native.reads, hasLength(1));
  expect(fixture.native.reads.single.result.isCompleted, isFalse);
  return (fixture: fixture, savedY: savedY, savedOffset: savedOffset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final floor in [0, 1]) {
    testWidgets(
      'nested list image growth preserves a leaf passage in floor $floor',
      (tester) async {
        final fixture = await _mount(
          tester,
          native: _MediaNative(mediaFloor: floor, nestedList: true),
        );
        await _place(tester, fixture, _text(_after));
        final y = tester.getTopLeft(_text(_after)).dy;
        final element = tester.element(_text(_after));
        final before = fixture.controller.offset;
        fixture.native.complete(_picture);
        await _frames(tester, 12);
        expect(tester.getSize(_decoded(_picture)).height, 900);
        expect(tester.getTopLeft(_text(_after)).dy, closeTo(y, 1));
        expect(tester.element(_text(_after)), same(element));
        expect(fixture.controller.offset, greaterThan(before + 700));
        fixture.expectRetained(tester);
        await _expectSaved(tester, fixture);
      },
    );

    testWidgets(
      'pending image growth preserves visible same-floor text in ${floor == 0 ? 'root' : 'long reply'}',
      (tester) async {
        final fixture = await _mount(
          tester,
          native: _MediaNative(mediaFloor: floor),
        );
        await _place(tester, fixture, _text(_after));
        expect(fixture.native.reads, hasLength(1));
        final y = tester.getTopLeft(_text(_after)).dy;
        final before = fixture.controller.offset;
        final element = tester.element(_text(_after));
        fixture.native.complete(_picture);
        await _frames(tester, 12);
        expect(tester.getSize(_decoded(_picture)).height, 900);
        expect(tester.getTopLeft(_text(_after)).dy, closeTo(y, 1));
        expect(tester.element(_text(_after)), same(element));
        expect(fixture.controller.offset, greaterThan(before + 700));
        await _expectSaved(tester, fixture);
      },
    );

    testWidgets(
      'late image geometry waits for an active drag in ${floor == 0 ? 'root' : 'long reply'} and preserves the latest passage at idle',
      (tester) async {
        final fixture = await _mount(
          tester,
          native: _MediaNative(mediaFloor: floor),
        );
        await _place(tester, fixture, _text(_after));
        final paragraph = tester.element(_text(_after));
        final gesture = await tester.startGesture(tester.getCenter(_scroll));
        await gesture.moveBy(const Offset(0, -60));
        await tester.pump(const Duration(milliseconds: 16));
        expect(fixture.controller.position.isScrollingNotifier.value, isTrue);
        final movingY = tester.getTopLeft(_text(_after)).dy;
        final movingOffset = fixture.controller.offset;

        fixture.native.complete(_picture);
        await _frames(tester);
        expect(tester.getTopLeft(_text(_after)).dy, closeTo(movingY, 1));
        expect(tester.getSize(_decoded(_picture)).height, 120);
        expect(fixture.controller.offset, closeTo(movingOffset, 1));
        expect(fixture.controller.position.isScrollingNotifier.value, isTrue);

        await gesture.moveBy(const Offset(0, -24));
        await tester.pump(const Duration(milliseconds: 16));
        expect(fixture.controller.offset, greaterThan(movingOffset));
        final latestY = tester.getTopLeft(_text(_after)).dy;
        final latestOffset = fixture.controller.offset;
        expect(latestY, closeTo(movingY - (latestOffset - movingOffset), 1));
        await tester.pump(const Duration(milliseconds: 200));
        await gesture.up();
        await _frames(tester, 16);

        expect(fixture.controller.position.isScrollingNotifier.value, isFalse);
        expect(tester.getSize(_decoded(_picture)).height, 900);
        expect(tester.getTopLeft(_text(_after)).dy, closeTo(latestY, 1));
        expect(fixture.controller.offset, closeTo(latestOffset + 780, 1));
        expect(tester.element(_text(_after)), same(paragraph));
        await _expectSaved(tester, fixture);
      },
    );

    testWidgets(
      'cold reader restoration waits for unknown image geometry in ${floor == 0 ? 'root' : 'long reply'} without losing the saved passage',
      (tester) async {
        final first = await _mount(
          tester,
          native: _MediaNative(mediaFloor: floor),
        );
        // The original session really reads and lays out the image before the
        // user reaches the following passage and the save debounce matures.
        first.native.complete(_picture);
        await _frames(tester, 12);
        await _place(tester, first, _text(_after));
        await _expectSaved(tester, first);
        final savedY = tester.getTopLeft(_text(_after)).dy;
        final savedOffset = first.controller.offset;
        final saved = jsonMap(jsonDecode(jsonEncode(first.native.saves.last)));
        final savedAnchor = jsonMap(saved['bodyAnchor']);
        expect(savedAnchor['floor'], '$floor');
        expect(numberValue(saved['offset']), closeTo(savedOffset, 1));
        expect(tester.getSize(_decoded(_picture)).height, 900);

        // Destroy both the production reader and its AppState; only the real
        // position DTO crosses this boundary. No image cache/geometry, content
        // leaf, ScrollController or AppState readerOffset is reused.
        await first.dispose();
        expect(_reader, findsNothing);
        final native = _MediaNative(mediaFloor: floor, restoredPosition: saved);
        final restored = await _mount(tester, native: native);
        expect(restored.state, isNot(same(first.state)));
        expect(restored.readerState, isNot(same(first.readerState)));
        expect(restored.controller, isNot(same(first.controller)));
        expect(restored.state.imageDimensions(_picture), isEmpty);
        expect(native.reads, hasLength(1));
        expect(native.reads.single.result.isCompleted, isFalse);
        expect(_decoded(_picture), findsNothing);

        // Let ordinary restore callbacks and the 600ms position debounce run
        // while the new image is still pending. This must not convert temporary
        // placeholder geometry into a zero or replace the durable destination.
        await tester.pump(const Duration(milliseconds: 900));
        await _frames(tester, 12);
        expect(restored.state.imageDimensions(_picture), isEmpty);
        expect(native.reads.single.result.isCompleted, isFalse);
        expect(
          native.saves.every((value) => numberValue(value['offset']) > 0),
          isTrue,
          reason: 'A fresh reader with pending media must not persist zero.',
        );

        native.complete(_picture);
        await _frames(tester, 16);
        expect(tester.getSize(_decoded(_picture)).height, 900);
        expect(
          tester.getTopLeft(_text(_after)).dy,
          closeTo(savedY, 1),
          reason: 'Cold media reflow must return to the saved passage, not a later paragraph visible only with the short placeholder.',
        );
        expect(_text(_after).hitTestable(), findsOneWidget);
        expect(restored.controller.offset, closeTo(savedOffset, 1));
        await _expectSaved(tester, restored);
        final finalSave = native.saves.last;
        expect(numberValue(finalSave['offset']), closeTo(savedOffset, 1));
        expect(jsonMap(finalSave['bodyAnchor'])['floor'], savedAnchor['floor']);
        expect(
          numberValue(jsonMap(finalSave['bodyAnchor'])['dy']),
          closeTo(numberValue(savedAnchor['dy']), 1),
        );
        expect(native.reads, hasLength(1));
        expect(
          native.calls.where(
            (method) =>
                method == 'reader.load' ||
                method == 'reader.sendReply' ||
                method == 'reader.edit.save' ||
                method == 'discussion.publish',
          ),
          isEmpty,
        );
      },
    );
  }

  testWidgets(
    'cached true dimensions survive eviction and an idle callback waits for a resumed drag',
    (tester) async {
      final fixture = await _mount(
        tester,
        native: _MediaNative(imageSize: const {'width': 160, 'height': 100}),
      );
      await _place(tester, fixture, _text(_after));
      final request = fixture.state.image(_picture);
      final first = await tester.startGesture(tester.getCenter(_scroll));
      await first.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 16));
      fixture.native.complete(_picture);
      await _frames(tester);
      expect(tester.getSize(_decoded(_picture)).height, 100);
      expect(fixture.controller.position.isScrollingNotifier.value, isTrue);
      expect(
        fixture.state.evictImageFuture(
          _picture,
          request,
          revision: fixture.state.accessRevision,
        ),
        isTrue,
      );
      expect(fixture.state.imageDimensions(_picture), isEmpty);
      await first.up();
      expect(fixture.controller.position.isScrollingNotifier.value, isFalse);
      final second = await tester.startGesture(tester.getCenter(_scroll));
      await second.moveBy(const Offset(0, -60));
      expect(fixture.controller.position.isScrollingNotifier.value, isTrue);
      await _frames(tester);
      expect(tester.getSize(_decoded(_picture)).height, 100);
      final before = fixture.controller.offset;
      await second.moveBy(const Offset(0, -24));
      await tester.pump(const Duration(milliseconds: 16));
      expect(fixture.controller.offset, greaterThan(before));
      final latestY = tester.getTopLeft(_text(_after)).dy;
      final latestOffset = fixture.controller.offset;
      await second.up();
      await _frames(tester, 16);
      expect(fixture.controller.position.isScrollingNotifier.value, isFalse);
      expect(tester.getSize(_decoded(_picture)).height, 900);
      expect(tester.getTopLeft(_text(_after)).dy, closeTo(latestY, 1));
      expect(fixture.controller.offset, closeTo(latestOffset + 800, 1));
      expect(fixture.native.reads, hasLength(1));
      await _expectSaved(tester, fixture);
    },
  );

  testWidgets(
    'late image geometry waits through the default keyboard page animation',
    (tester) async {
      final fixture = await _mount(tester);
      await _place(tester, fixture, _text(_after));
      final passage = _text('Long same-floor continuation 20');
      final beforeY = tester.getTopLeft(passage).dy;
      final beforeOffset = fixture.controller.offset;
      final pageDelta = fixture.controller.position.viewportDimension * .8;
      Actions.invoke(
        tester.element(_text(_after)),
        const ScrollIntent(
          direction: AxisDirection.down,
          type: ScrollIncrementType.page,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(fixture.controller.position.isScrollingNotifier.value, isTrue);
      expect(fixture.controller.offset, greaterThan(beforeOffset));
      fixture.native.complete(_picture);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(fixture.controller.position.isScrollingNotifier.value, isTrue);
      expect(tester.getSize(_decoded(_picture)).height, 120);
      await tester.pump(const Duration(milliseconds: 250));
      await _frames(tester, 16);
      expect(fixture.controller.position.isScrollingNotifier.value, isFalse);
      expect(tester.getSize(_decoded(_picture)).height, 900);
      expect(tester.getTopLeft(passage).dy, closeTo(beforeY - pageDelta, 1));
      expect(
        fixture.controller.offset,
        closeTo(beforeOffset + pageDelta + 780, 1),
      );
      await _expectSaved(tester, fixture);
    },
  );

  testWidgets(
    'replacing a waiting image retires its old idle geometry update',
    (tester) async {
      final fixture = await _mount(tester);
      await _place(tester, fixture, _text(_after));
      final gesture = await tester.startGesture(tester.getCenter(_scroll));
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 16));
      fixture.native.complete(_picture);
      await _frames(tester);
      expect(fixture.controller.position.isScrollingNotifier.value, isTrue);
      expect(tester.getSize(_decoded(_picture)).height, 120);
      final beforeY = tester.getTopLeft(_text(_after)).dy;
      final snapshot = fixture.native.snapshot;
      final thread = jsonMap(snapshot['thread']);
      final root = jsonMap(thread['root']);
      fixture.state.readers[_url] = {
        ...snapshot,
        'thread': {
          ...thread,
          'root': {
            ...root,
            'blocks': [
              for (final block in jsonItems(root['blocks']))
                block['kind'] == 'image' ? {...block, 'url': _tq} : block,
            ],
          },
        },
      };
      fixture.state.notifyListeners();
      await _frames(tester);
      expect(_image(_picture), findsNothing);
      expect(_image(_tq), findsOneWidget);
      expect(_decoded(_tq), findsNothing);
      await gesture.up();
      await _frames(tester, 16);
      expect(tester.getTopLeft(_text(_after)).dy, closeTo(beforeY, 1));
      expect(_decoded(_tq), findsNothing);
      fixture.native.complete(_tq, tall: false);
      await _frames(tester, 16);
      expect(tester.getSize(_decoded(_tq)).height, 100);
      expect(tester.getTopLeft(_text(_after)).dy, closeTo(beforeY, 1));
      expect(fixture.native.reads, hasLength(2));
      await _expectSaved(tester, fixture);
    },
  );

  testWidgets(
    'cold pending media parks without position writes, repeated jumps or extra reads',
    (tester) async {
      final cold = await _coldRoot(tester);
      final fixture = cold.fixture;
      final initial = fixture.controller.offset;
      final notifications = <double>[];
      void changed() => notifications.add(fixture.controller.offset);
      fixture.controller.addListener(changed);
      try {
        // Deliberately cross the normal save debounce repeatedly. The image
        // spinner may schedule frames; it must not start another seek/save.
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(milliseconds: 120));
          expect(fixture.controller.offset, closeTo(initial, .1));
          expect(fixture.native.saves, isEmpty);
          expect(fixture.native.reads, hasLength(1));
          expect(fixture.native.reads.single.result.isCompleted, isFalse);
        }
        expect(
          notifications,
          isEmpty,
          reason: 'Waiting for geometry must not poll by repeatedly jumping.',
        );
      } finally {
        fixture.controller.removeListener(changed);
      }
      fixture.native.complete(_picture);
      await _frames(tester, 16);
      expect(tester.getTopLeft(_text(_after)).dy, closeTo(cold.savedY, 1));
      expect(fixture.controller.offset, closeTo(cold.savedOffset, 1));
      await _expectSaved(tester, fixture);
    },
  );

  testWidgets(
    'wheel input cancels cold media restoration and late image growth preserves the user passage',
    (tester) async {
      final cold = await _coldRoot(tester);
      final fixture = cold.fixture;
      await tester.pump(const Duration(milliseconds: 950));
      expect(fixture.native.saves, isEmpty);
      final beforeWheel = fixture.controller.offset;
      tester.binding.handlePointerEvent(
        PointerScrollEvent(
          position: tester.getCenter(_scroll),
          scrollDelta: const Offset(0, 72),
          kind: PointerDeviceKind.mouse,
        ),
      );
      expect(fixture.controller.offset, closeTo(beforeWheel + 72, 1));
      await _frames(tester);
      final viewport = tester.getRect(_scroll);
      Finder? passage;
      for (var line = 0; line < 24; line++) {
        final candidate = _text('Long same-floor continuation $line');
        if (candidate.evaluate().isEmpty) continue;
        final rect = tester.getRect(candidate);
        if (rect.top >= viewport.top && rect.bottom < viewport.bottom) {
          passage = candidate;
          break;
        }
      }
      expect(
        passage,
        isNotNull,
        reason: 'The real wheel must leave a same-floor passage to anchor.',
      );
      final target = passage!;
      final userY = tester.getTopLeft(target).dy;
      final userOffset = fixture.controller.offset;
      await _expectSaved(tester, fixture);
      fixture.native.complete(_picture);
      await _frames(tester, 16);
      expect(tester.getTopLeft(target).dy, closeTo(userY, 1));
      expect(fixture.controller.offset, greaterThan(userOffset + 700));
      expect(fixture.controller.offset, isNot(closeTo(cold.savedOffset, 1)));
      expect(
        tester.getTopLeft(_text(_after)).dy,
        isNot(closeTo(cold.savedY, 1)),
      );
      await _expectSaved(tester, fixture);
    },
  );

  for (final block in ['code', 'table']) {
    for (final input in ['horizontal wheel', 'shift wheel', 'trackpad pan']) {
      testWidgets('$input in a wide $block preserves cold media restoration', (
        tester,
      ) async {
        final cold = await _coldRoot(tester, horizontalBlock: block);
        final fixture = cold.fixture;
        final horizontal = _horizontalContent;
        expect(horizontal.hitTestable(), findsOneWidget);
        final inner = Scrollable.of(tester.element(_text(_wideContent)))
            .position;
        expect(inner.axis, Axis.horizontal);
        expect(inner.maxScrollExtent, greaterThan(144));
        expect(inner.pixels, 0);
        final outerOffset = fixture.controller.offset;
        final center = tester.getCenter(horizontal);
        if (input == 'trackpad pan') {
          final gesture = await tester.createGesture(
            kind: PointerDeviceKind.trackpad,
          );
          await gesture.panZoomStart(center);
          await gesture.panZoomUpdate(center, pan: const Offset(-72, 0));
          await tester.pump(const Duration(milliseconds: 16));
          await gesture.panZoomUpdate(center, pan: const Offset(-144, 0));
          await tester.pump(const Duration(milliseconds: 200));
          await gesture.panZoomEnd();
        } else {
          final shift = input == 'shift wheel';
          if (shift) {
            await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          }
          try {
            await tester.sendEventToBinding(
              PointerScrollEvent(
                position: center,
                scrollDelta: shift ? const Offset(0, 72) : const Offset(72, 0),
                kind: PointerDeviceKind.mouse,
              ),
            );
          } finally {
            if (shift) {
              await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
            }
          }
        }
        await _frames(tester);
        expect(inner.pixels, greaterThan(0));
        expect(fixture.controller.offset, closeTo(outerOffset, .1));
        await tester.pump(const Duration(milliseconds: 950));
        expect(fixture.controller.offset, closeTo(outerOffset, .1));
        expect(fixture.native.saves, isEmpty);
        expect(fixture.native.reads, hasLength(1));
        expect(fixture.native.reads.single.result.isCompleted, isFalse);
        fixture.native.complete(_picture);
        await _frames(tester, 16);
        expect(tester.getSize(_decoded(_picture)).height, 900);
        expect(tester.getTopLeft(_text(_after)).dy, closeTo(cold.savedY, 1));
        expect(fixture.controller.offset, closeTo(cold.savedOffset, 1));
        expect(fixture.native.reads, hasLength(1));
        await _expectSaved(tester, fixture);
      });
    }
    for (final input in ['wheel', 'trackpad pan']) {
      testWidgets(
        'vertical $input over a wide $block takes over cold media restoration',
        (tester) async {
          final cold = await _coldRoot(tester, horizontalBlock: block);
          final fixture = cold.fixture;
          expect(_horizontalContent.hitTestable(), findsOneWidget);
          final inner = Scrollable.of(tester.element(_text(_wideContent)))
              .position;
          final before = fixture.controller.offset;
          final center = tester.getCenter(_horizontalContent);
          expect(fixture.native.saves, isEmpty);
          if (input == 'wheel') {
            await tester.sendEventToBinding(
              PointerScrollEvent(
                position: center,
                scrollDelta: const Offset(0, 72),
                kind: PointerDeviceKind.mouse,
              ),
            );
          } else {
            final gesture = await tester.createGesture(
              kind: PointerDeviceKind.trackpad,
            );
            await gesture.panZoomStart(center);
            await gesture.panZoomUpdate(center, pan: const Offset(0, -40));
            await tester.pump(const Duration(milliseconds: 16));
            await gesture.panZoomUpdate(center, pan: const Offset(0, -80));
            await tester.pump(const Duration(milliseconds: 200));
            await gesture.panZoomEnd();
          }
          await _frames(tester);
          expect(inner.pixels, 0);
          final userOffset = fixture.controller.offset;
          expect(userOffset, greaterThan(before));
          final viewport = tester.getRect(_scroll);
          final passage =
              [
                for (var line = 0; line < 24; line++)
                  _text('Long same-floor continuation $line'),
                _text(_wideContent),
              ].firstWhere((candidate) {
                if (candidate.evaluate().isEmpty) return false;
                final rect = tester.getRect(candidate);
                return rect.top >= viewport.top &&
                    rect.bottom < viewport.bottom;
              });
          final userY = tester.getTopLeft(passage).dy;
          await _expectSaved(tester, fixture);
          expect(fixture.native.reads, hasLength(1));
          expect(fixture.native.reads.single.result.isCompleted, isFalse);
          fixture.native.complete(_picture);
          await _frames(tester, 16);
          expect(tester.getTopLeft(passage).dy, closeTo(userY, 1));
          expect(fixture.controller.offset, greaterThan(userOffset + 700));
          expect(
            fixture.controller.offset,
            isNot(closeTo(cold.savedOffset, 1)),
          );
          expect(
            tester.getTopLeft(_text(_after)).dy,
            isNot(closeTo(cold.savedY, 1)),
          );
          await _expectSaved(tester, fixture);
        },
      );
    }
  }

  for (final input in [
    'stationary',
    'horizontal',
    'vertical acceptance only',
  ]) {
    final competingAxes = input == 'vertical acceptance only';
    testWidgets(
      '$input trackpad gesture over ${competingAxes ? 'wide code' : 'ordinary text'} preserves cold media restoration',
      (tester) async {
        final cold = await _coldRoot(
          tester,
          horizontalBlock: competingAxes ? 'code' : null,
        );
        final fixture = cold.fixture;
        final before = fixture.controller.offset;
        final target = competingAxes ? _horizontalContent : _scroll;
        expect(target.hitTestable(), findsOneWidget);
        final center = tester.getCenter(target);
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.trackpad,
        );
        await gesture.panZoomStart(center);
        await tester.pump();
        if (input == 'horizontal') {
          await gesture.panZoomUpdate(center, pan: const Offset(-72, 0));
          await tester.pump(const Duration(milliseconds: 16));
          await gesture.panZoomUpdate(center, pan: const Offset(-144, 0));
          await tester.pump(const Duration(milliseconds: 200));
        } else if (input == 'vertical acceptance only') {
          await gesture.panZoomUpdate(center, pan: const Offset(0, -40));
          await tester.pump(const Duration(milliseconds: 200));
          expect(fixture.controller.position.isScrollingNotifier.value, isTrue);
          expect(fixture.controller.offset, closeTo(before, .1));
        }
        await gesture.panZoomEnd();
        await _frames(tester);
        expect(fixture.controller.offset, closeTo(before, .1));
        await tester.pump(const Duration(milliseconds: 950));
        expect(fixture.native.saves, isEmpty);
        expect(fixture.native.reads, hasLength(1));
        expect(fixture.native.reads.single.result.isCompleted, isFalse);
        fixture.native.complete(_picture);
        await _frames(tester, 16);
        expect(tester.getTopLeft(_text(_after)).dy, closeTo(cold.savedY, 1));
        expect(fixture.controller.offset, closeTo(cold.savedOffset, 1));
        await _expectSaved(tester, fixture);
      },
    );
  }

  testWidgets(
    'default keyboard page action cancels cold media parking and retains the new passage after image arrival',
    (tester) async {
      final cold = await _coldRoot(tester);
      final fixture = cold.fixture;
      await tester.pump(const Duration(milliseconds: 950));
      expect(fixture.native.saves, isEmpty);
      expect(fixture.state.imageDimensions(_picture), isEmpty);
      expect(fixture.native.reads.single.result.isCompleted, isFalse);
      final beforePage = fixture.controller.offset;
      final viewportHeight = fixture.controller.position.viewportDimension;

      // PageUp maps to this ScrollIntent in WidgetsApp.defaultShortcuts. Invoke
      // its inherited Action from a real body descendant so the framework's
      // ScrollAction resolves the production reader and performs its animated
      // position.moveTo. No wheel, tap, private handler or direct jump is used.
      final actionContext = tester.element(_text(_after));
      expect(
        Scrollable.of(actionContext).position,
        same(fixture.controller.position),
      );
      Actions.invoke(
        actionContext,
        const ScrollIntent(
          direction: AxisDirection.up,
          type: ScrollIncrementType.page,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      await _frames(tester);
      final userOffset = fixture.controller.offset;
      expect(userOffset, closeTo(beforePage - viewportHeight * .8, 1));
      expect(userOffset, greaterThan(0));

      final viewport = tester.getRect(_scroll);
      Finder? passage;
      for (var line = 0; line < 24; line++) {
        final candidate = _text('Long same-floor continuation $line');
        if (candidate.evaluate().isEmpty) continue;
        final rect = tester.getRect(candidate);
        if (rect.top >= viewport.top && rect.bottom < viewport.bottom) {
          passage = candidate;
          break;
        }
      }
      expect(
        passage,
        isNotNull,
        reason: 'The default page action must reveal a new same-floor passage.',
      );
      final target = passage!;
      final userY = tester.getTopLeft(target).dy;
      expect(fixture.native.reads, hasLength(1));
      fixture.native.complete(_picture);
      await _frames(tester, 16);
      expect(tester.getSize(_decoded(_picture)).height, 900);
      expect(tester.getTopLeft(target).dy, closeTo(userY, 1));
      expect(fixture.controller.offset, greaterThan(userOffset + 700));
      expect(fixture.controller.offset, isNot(closeTo(cold.savedOffset, 1)));
      expect(
        tester.getTopLeft(_text(_after)).dy,
        isNot(closeTo(cold.savedY, 1)),
      );
      await _expectSaved(tester, fixture);
      expect(tester.getTopLeft(target).dy, closeTo(userY, 1));
    },
  );

  testWidgets(
    'cold unknown image failure and retry preserve the original destination until successful geometry arrives',
    (tester) async {
      final cold = await _coldRoot(tester);
      final fixture = cold.fixture;
      fixture.native.fail(_picture);
      await _frames(tester, 12);
      final failure = find.descendant(
        of: _image(_picture),
        matching: find.text('图片加载失败，点按重试'),
      );
      expect(failure, findsOneWidget);
      final failedOffset = fixture.controller.offset;
      await tester.pump(const Duration(milliseconds: 950));
      await _frames(tester);
      expect(fixture.native.saves, isEmpty);
      expect(fixture.controller.offset, closeTo(failedOffset, .1));
      expect(fixture.state.imageDimensions(_picture), isEmpty);
      expect(fixture.native.reads, hasLength(1));

      // The failed image is above the cold destination. Invoke the actual UI
      // retry callback without scrolling to reveal it: a synthetic scroll here
      // would intentionally cancel the restoration that this case exercises.
      final retry = find.descendant(
        of: _image(_picture),
        matching: find.byWidgetPredicate(
          (widget) => widget is GestureDetector && widget.onTap != null,
        ),
      );
      expect(retry, findsOneWidget);
      tester.widget<GestureDetector>(retry).onTap!();
      await _frames(tester);
      expect(fixture.native.reads, hasLength(2));
      expect(fixture.native.reads.last.result.isCompleted, isFalse);
      await tester.pump(const Duration(milliseconds: 950));
      expect(fixture.native.saves, isEmpty);
      fixture.native.complete(_picture);
      await _frames(tester, 16);
      expect(failure, findsNothing);
      expect(tester.getTopLeft(_text(_after)).dy, closeTo(cold.savedY, 1));
      expect(fixture.controller.offset, closeTo(cold.savedOffset, 1));
      expect(fixture.native.reads, hasLength(2));
      await _expectSaved(tester, fixture);
    },
  );

  testWidgets(
    'real wheel input takes over a pending image compensation transaction',
    (tester) async {
      final fixture = await _mount(tester);
      await _place(tester, fixture, _text(_after));
      final pointer = tester.getCenter(_scroll);
      double? beforeWheel, wheelOffset;
      // Runs after the image's new layout, before the restore callback which
      // that layout registers. Dispatch through Flutter's real pointer resolver.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        beforeWheel = fixture.controller.offset;
        tester.binding.handlePointerEvent(
          PointerScrollEvent(
            position: pointer,
            scrollDelta: const Offset(0, 72),
            kind: PointerDeviceKind.mouse,
          ),
        );
        wheelOffset = fixture.controller.offset;
      });
      fixture.native.complete(_picture);
      await tester.pump();
      expect(wheelOffset, closeTo(beforeWheel! + 72, 1));
      await _frames(tester, 12);
      expect(tester.getSize(_decoded(_picture)).height, 900);
      expect(fixture.controller.offset, closeTo(wheelOffset!, 1));
      await _expectSaved(tester, fixture);
      expect(fixture.controller.offset, closeTo(wheelOffset!, 1));
    },
  );

  testWidgets(
    'NQ and TQ settings resize reports while the passage below stays in place',
    (tester) async {
      final fixture = await _mount(tester, native: _MediaNative(reports: true));
      fixture.native.complete(_nq);
      fixture.native.complete(_tq);
      await _frames(tester, 12);
      for (final report in [('nq', _nq, _afterNq), ('tq', _tq, _afterTq)]) {
        await _place(tester, fixture, _text(report.$3));
        final y = tester.getTopLeft(_text(report.$3)).dy;
        final initial = tester.getSize(_decoded(report.$2));
        for (final scale in [150.0, 100.0]) {
          await fixture.state.act('settings.update', {
            'key': 'workspace.${report.$1}ReportScale',
            'value': scale,
          }, 'settings');
          await _frames(tester, 12);
          final current = tester.getSize(_decoded(report.$2));
          expect(current.height, closeTo(initial.height * scale / 100, 1));
          expect(current.width, closeTo(initial.width * scale / 100, 1));
          expect(tester.getTopLeft(_text(report.$3)).dy, closeTo(y, 1));
          if (report.$1 == 'nq') {
            expect(
              current.height,
              greaterThan(fixture.controller.position.viewportDimension),
            );
            expect(current.height / current.width, closeTo(900 / 160, .001));
          }
          await _expectSaved(tester, fixture);
        }
      }
    },
  );

  testWidgets(
    'same-frame reader width and NQ image reflow preserve the passage until real wheel input takes over',
    (tester) async {
      final fixture = await _mount(tester, native: _MediaNative(reports: true));
      fixture.native.complete(_nq);
      fixture.native.complete(_tq);
      await _frames(tester, 12);
      await _place(tester, fixture, _text(_afterNq));
      final y = tester.getTopLeft(_text(_afterNq)).dy;
      final element = tester.element(_text(_afterNq));
      final wideImage = tester.getSize(_decoded(_nq));
      final wideOffset = fixture.controller.offset;

      // One parent resize triggers both the Reader's geometry transaction and
      // the already decoded image's narrower layout in the same frame. An
      // earlier floor-only transaction must not mask the media content point.
      fixture.host.currentState!.resizeWidth(520);
      await tester.pump();
      await _frames(tester, 12);
      final narrowImage = tester.getSize(_decoded(_nq));
      expect(tester.getSize(_scroll).width, 520);
      expect(narrowImage.width, lessThan(wideImage.width - 100));
      expect(narrowImage.height, lessThan(wideImage.height - 500));
      expect(narrowImage.height / narrowImage.width, closeTo(900 / 160, .001));
      expect(tester.getTopLeft(_text(_afterNq)).dy, closeTo(y, 1));
      expect(tester.element(_text(_afterNq)), same(element));
      expect(fixture.controller.offset, lessThan(wideOffset - 500));
      await _expectSaved(tester, fixture);

      fixture.host.currentState!.resizeWidth(760);
      await _frames(tester, 12);
      expect(tester.getSize(_decoded(_nq)), wideImage);
      expect(tester.getTopLeft(_text(_afterNq)).dy, closeTo(y, 1));
      await _expectSaved(tester, fixture);

      final pointer = tester.getTopLeft(_scroll) + const Offset(120, 120);
      double? beforeWheel, wheelOffset;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        beforeWheel = fixture.controller.offset;
        tester.binding.handlePointerEvent(
          PointerScrollEvent(
            position: pointer,
            scrollDelta: const Offset(0, 72),
            kind: PointerDeviceKind.mouse,
          ),
        );
        wheelOffset = fixture.controller.offset;
      });
      fixture.host.currentState!.resizeWidth(520);
      await tester.pump();
      expect(wheelOffset, closeTo(beforeWheel! + 72, 1));
      await _frames(tester, 12);
      expect(tester.getSize(_decoded(_nq)), narrowImage);
      expect(fixture.controller.offset, closeTo(wheelOffset!, 1));
      expect(tester.getTopLeft(_text(_afterNq)).dy, isNot(closeTo(y, 1)));
      await _expectSaved(tester, fixture);
      expect(fixture.controller.offset, closeTo(wheelOffset!, 1));
    },
  );

  testWidgets(
    'TQ adapts to the actual shorter reader viewport while NQ remains a complete long image',
    (tester) async {
      final fixture = await _mount(tester, native: _MediaNative(reports: true));
      fixture.native.complete(_nq);
      fixture.native.complete(_tq);
      await _frames(tester, 12);
      await _place(tester, fixture, _text(_afterTq));
      final initialTq = tester.getSize(_decoded(_tq));
      final initialNq = tester.getSize(_decoded(_nq));
      final y = tester.getTopLeft(_text(_afterTq)).dy;
      fixture.host.currentState!.resizeHeight(540);
      await _frames(tester, 12);
      final viewport = tester.getSize(_scroll).height;
      final tq = tester.getSize(_decoded(_tq));
      final budget = (viewport * .55).clamp(160.0, 440.0);
      expect(viewport, lessThan(540));
      expect(tq.height, lessThan(initialTq.height - 80));
      expect(
        tq.height,
        closeTo(budget * 1.75, 1),
        reason: 'Use the reader scroll viewport, not the 920px application surface.',
      );
      expect(tester.getSize(_decoded(_nq)), initialNq);
      expect(initialNq.height, greaterThan(viewport * 3));
      expect(initialNq.height / initialNq.width, closeTo(900 / 160, .001));
      expect(tester.getTopLeft(_text(_afterTq)).dy, closeTo(y, 1));
      await _expectSaved(tester, fixture);
    },
  );

  testWidgets(
    'a real Reader image opens and closes its viewer without replacing reader, position or reply draft',
    (tester) async {
      final fixture = await _mount(tester);
      fixture.native.complete(_picture, tall: false);
      await _frames(tester, 12);
      await tester.tap(_button('写回复'));
      await _frames(tester, 12);
      expect(find.byType(ComposerScreen), findsOneWidget);
      final editorElement = tester.element(find.byType(ComposerScreen));
      final draft = tester.widget<CupertinoTextField>(_editorBody).controller!;
      expect(draft.text, _draft);
      draft.selection = const TextSelection(baseOffset: 2, extentOffset: 7);
      final editing = draft.value;
      await _place(tester, fixture, _decoded(_picture), dy: 24);
      final position = fixture.controller.offset;
      await tester.tap(_decoded(_picture));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320));
      expect(find.byType(NativeImageViewer), findsOneWidget);
      expect(
        fixture.native.reads.where((read) => read.kind == 'original'),
        hasLength(1),
      );
      fixture.native.complete(_picture, kind: 'original', tall: false);
      await _frames(tester);
      expect(fixture.controller.offset, closeTo(position, 1));
      expect(draft.value, editing);
      await tester.tap(find.byKey(ImageViewerToolbar.closeKey));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320));
      await _frames(tester);
      expect(find.byType(NativeImageViewer), findsNothing);
      expect(tester.element(find.byType(ComposerScreen)), same(editorElement));
      expect(
        tester.widget<CupertinoTextField>(_editorBody).controller,
        same(draft),
      );
      expect(draft.value, editing);
      expect(fixture.native.draft, _draft);
      expect(fixture.controller.offset, closeTo(position, 1));
      fixture.expectRetained(tester);
      expect(
        fixture.native.calls.where((method) => method == 'reader.replyDraft'),
        hasLength(1),
      );
      expect(
        fixture.native.calls.where(
          (method) =>
              method == 'reader.load' ||
              method == 'reader.sendReply' ||
              method == 'reader.edit.save' ||
              method == 'discussion.publish',
        ),
        isEmpty,
      );
    },
  );
}
