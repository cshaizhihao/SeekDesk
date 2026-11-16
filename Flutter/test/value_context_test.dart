import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/tools_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';

typedef _Context = ({String? topic, String? title, bool visible});
const _amount = '例如 35.99';
const _expires = 'YYYY-MM-DD';
const _asOf = '计算基准日 YYYY-MM-DD';
const _asking = '例如 180';

class _Request {
  _Request(this.arguments);
  final JsonMap arguments;
  final completion = Completer<JsonMap>();
}

/// All service responses, pending requests and clipboard writes stay in memory.
/// Unknown native calls are recorded before throwing, so a caught production
/// failure cannot silently make this fixture contact a real service.
class _Native extends NativeClient {
  _Native()
    : super(methods: MethodChannel('seekdesk.test.value-context.${_next++}'));
  static int _next = 0;
  final calls = <(String, JsonMap)>[];
  final unexpected = <String>[];
  final hints = <_Request>[];
  final calculations = <_Request>[];
  JsonMap? rateResponse;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) {
    calls.add((method, {...arguments}));
    switch (method) {
      case 'value.currencies':
        return Future.value({
          'items': [
            {'code': 'USD', 'title': 'USD 美元'},
            {'code': 'CNY', 'title': 'CNY 人民币'},
            {'code': 'JPY', 'title': 'JPY 日元'},
          ],
        });
      case 'value.rate':
        return Future.value(
          rateResponse ??
              {
                'base': arguments['base'],
                'quote': arguments['quote'],
                'rate': '7.2',
                'source': 'In-memory fixture rate',
                'caption': '参考汇率',
                'asOf': DateTime(2027, 1, 1).millisecondsSinceEpoch.toDouble(),
              },
        );
      case 'value.hint':
        final request = _Request({...arguments});
        hints.add(request);
        return request.completion.future;
      case 'value.calculate':
        final request = _Request({...arguments});
        calculations.add(request);
        return request.completion.future;
      default:
        unexpected.add(method);
        throw StateError('Unexpected value context fixture call: $method');
    }
  }

  void finishPending() {
    for (final request in hints) {
      if (!request.completion.isCompleted) {
        request.completion.complete({'available': false});
      }
    }
    for (final request in calculations) {
      if (!request.completion.isCompleted) request.completion.complete({});
    }
  }
}

class _State extends AppState {
  _State(_Native native) : super(client: native) {
    connecting = false;
    domains['session'] = {'account': 'signedIn', 'owner': 1};
  }

  void changeIdentity({int owner = 1, bool advanceRevision = true}) {
    if (advanceRevision) client.accessRevision++;
    domains['session'] = {'account': 'signedIn', 'owner': owner};
    notifyListeners();
  }
}

class _Fixture {
  _Fixture(String? topic, String? title)
    : context = ValueNotifier((topic: topic, title: title, visible: true)) {
    state = _State(native);
  }

  final native = _Native();
  late final _State state;
  final ValueNotifier<_Context> context;
  final clipboard = <String>[];

  Future<void> show(
    WidgetTester tester, {
    String? topic,
    String? title,
    bool remount = false,
  }) async {
    if (remount) {
      context.value = (topic: topic, title: title, visible: false);
      await _frames(tester);
    }
    context.value = (topic: topic, title: title, visible: true);
    await _frames(tester);
  }
}

Future<_Fixture> _mount(
  WidgetTester tester, {
  String? topic = '17',
  String? title,
  bool embedded = true,
  Size size = const Size(1000, 1000),
  double scale = 1,
  JsonMap? rateResponse,
}) async {
  final fixture = _Fixture(topic, title);
  fixture.native.rateResponse = rateResponse;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      fixture.clipboard.add(stringValue(jsonMap(call.arguments)['text']));
    } else if (call.method == 'Clipboard.getData') {
      return {'text': fixture.clipboard.lastOrNull ?? ''};
    } else if (call.method == 'Clipboard.hasStrings') {
      return {'value': fixture.clipboard.isNotEmpty};
    }
    return null;
  });
  await tester.binding.setSurfaceSize(size);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.native.finishPending();
    await _frames(tester);
    fixture.state.dispose();
    fixture.context.dispose();
    await tester.pump(const Duration(seconds: 1));
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    await tester.binding.setSurfaceSize(null);
    expect(fixture.native.unexpected, isEmpty);
    expect(tester.takeException(), isNull);
  });
  await tester.pumpWidget(
    GlassAdaptiveScope(
      minQuality: GlassQuality.minimal,
      maxQuality: GlassQuality.minimal,
      child: CupertinoApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: CupertinoPageScaffold(
          child: ValueListenableBuilder<_Context>(
            valueListenable: fixture.context,
            builder: (_, target, _) => target.visible
                ? ValueScreen(
                    state: fixture.state,
                    topicKey: target.topic,
                    topicTitle: target.title,
                    embedded: embedded,
                  )
                : const Center(child: Text('Fixture closed tool')),
          ),
        ),
      ),
    ),
  );
  await _frames(tester);
  return fixture;
}

Future<void> _frames(WidgetTester tester, [int count = 4]) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskButton && widget.label == label,
);
Finder _icon(String label) => find.byWidgetPredicate(
  (widget) => widget is DeskIcon && widget.label == label,
);
Finder _field(String placeholder) => find.byWidgetPredicate(
  (widget) => widget is CupertinoTextField && widget.placeholder == placeholder,
);
Finder _selector(String firstLabel) => find.byWidgetPredicate(
  (widget) =>
      widget is GlassSegmentedControl &&
      widget.segments.first.label == firstLabel,
);

Future<void> _reveal(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    final scrollable = find.descendant(
      of: find.byType(ValueScreen),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable &&
            (widget.axisDirection == AxisDirection.down ||
                widget.axisDirection == AxisDirection.up),
      ),
    );
    expect(scrollable, findsOneWidget);
    final position = tester.state<ScrollableState>(scrollable).position;
    Future<void> wheel(double delta) async {
      // A desktop wheel traverses the form even when the six vertical glass
      // segments occupy its viewport. A drag instead belongs to that control's
      // lens gesture, so it cannot stand in for this scrolling interaction.
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(scrollable),
          scrollDelta: Offset(0, delta),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await _frames(tester);
    }

    for (
      var attempt = 0;
      attempt < 80 && position.pixels > position.minScrollExtent + .5;
      attempt++
    ) {
      await wheel(-240);
    }
    expect(
      position.pixels,
      closeTo(position.minScrollExtent, .5),
      reason:
          'The value form must be reachable from its start using the wheel.',
    );
    for (
      var attempt = 0;
      attempt < 80 && target.evaluate().isEmpty;
      attempt++
    ) {
      final before = position.pixels;
      await wheel(180);
      if ((position.pixels - before).abs() < .5 &&
          position.pixels >= position.maxScrollExtent - .5) {
        break;
      }
    }
    expect(
      target,
      findsOneWidget,
      reason:
          'The value control must be reachable by bounded desktop scrolling.',
    );
  }
  await tester.ensureVisible(target);
  await _frames(tester);
}

Future<void> _fill(
  WidgetTester tester,
  String placeholder,
  String value,
) async {
  final field = _field(placeholder);
  await _reveal(tester, field);
  expect(field.hitTestable(), findsOneWidget);
  await tester.enterText(field, value);
  await _frames(tester);
}

Future<String> _text(WidgetTester tester, String placeholder) async {
  final field = _field(placeholder);
  await _reveal(tester, field);
  return tester.widget<CupertinoTextField>(field).controller!.text;
}

Future<void> _tap(WidgetTester tester, String label) async {
  final button = _button(label);
  await _reveal(tester, button);
  expect(button.hitTestable(), findsOneWidget);
  await tester.tap(button);
  await _frames(tester);
}

Future<void> _select(WidgetTester tester, String firstLabel, int index) async {
  final selector = _selector(firstLabel);
  await _reveal(tester, selector);
  tester.widget<GlassSegmentedControl>(selector).onSegmentSelected(index);
  await _frames(tester);
}

Future<void> _currency(
  WidgetTester tester,
  String current,
  String label,
) async {
  await _tap(tester, current);
  await tester.tap(find.widgetWithText(CupertinoActionSheetAction, label));
  await tester.pumpAndSettle(
    const Duration(milliseconds: 40),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 3),
  );
}

Future<void> _validDates(WidgetTester tester) async {
  await _fill(tester, _asOf, '2027-01-01');
  await _fill(tester, _expires, '2027-07-03');
}

JsonMap _result(_Request request, {String formatted = '130.46 CNY'}) => {
  'amount': '17.995',
  'days': 183,
  'fullCycles': 0,
  'partialDays': 183,
  'partialCycleDays': 365,
  'base': request.arguments['base'],
  'quote': request.arguments['quote'],
  'asOf': request.arguments['asOf'],
  'expires': request.arguments['expires'],
  'formatted': formatted,
  'converted': '130.46',
  'differenceLabel': '溢价',
  'differenceAmount': '49.54 CNY',
};

void _testMac(String description, WidgetTesterCallback body) => testWidgets(
  description,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.macOS),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  _testMac('reopening a topic restores every value input and currency choice', (
    tester,
  ) async {
    final f = await _mount(tester);
    await _fill(tester, _amount, ' 135.99 ');
    await _validDates(tester);
    await _currency(tester, 'USD', 'JPY 日元');
    await _currency(tester, 'CNY', 'USD 美元');
    await _select(tester, '月付', 5);
    await _select(tester, '自动汇率', 1);
    await _fill(tester, '1 JPY 等于多少 USD', '0.00675');
    await _fill(tester, _asking, ' 29.5 ');
    await f.show(tester, topic: '17', remount: true);
    expect(await _text(tester, _amount), ' 135.99 ');
    expect(await _text(tester, _asOf), '2027-01-01');
    expect(await _text(tester, _expires), '2027-07-03');
    await _reveal(tester, _selector('月付'));
    expect(
      tester.widget<GlassSegmentedControl>(_selector('月付')).selectedIndex,
      5,
    );
    await _reveal(tester, _selector('自动汇率'));
    expect(
      tester.widget<GlassSegmentedControl>(_selector('自动汇率')).selectedIndex,
      1,
    );
    expect(await _text(tester, '1 JPY 等于多少 USD'), '0.00675');
    expect(await _text(tester, _asking), ' 29.5 ');
    expect(f.native.calculations, isEmpty);
    expect(f.native.hints, isEmpty);
  });

  _testMac(
    'topic drafts remain independent and never leak into standalone use',
    (tester) async {
      final f = await _mount(tester);
      await _fill(tester, _amount, '17.25');
      await _fill(tester, _expires, '2027-06-17');
      await f.show(tester, topic: '42');
      expect(await _text(tester, _amount), isEmpty);
      expect(await _text(tester, _expires), isEmpty);
      await _fill(tester, _amount, '42.5');
      await f.show(tester);
      expect(await _text(tester, _amount), isEmpty);
      await _fill(tester, _amount, '9.75');
      await f.show(tester, topic: '17');
      expect(await _text(tester, _amount), '17.25');
      expect(await _text(tester, _expires), '2027-06-17');
      await f.show(tester, topic: '42', remount: true);
      expect(await _text(tester, _amount), '42.5');
      await f.show(tester, remount: true);
      expect(await _text(tester, _amount), '9.75');
    },
  );

  _testMac(
    'reopening retains an explicitly cleared calculation date for correction',
    (tester) async {
      final f = await _mount(tester);
      await _fill(tester, _amount, '35.99');
      await _fill(tester, _expires, '2027-07-03');
      await _fill(tester, _asOf, '');
      await f.show(tester, topic: '17', remount: true);
      expect(await _text(tester, _asOf), isEmpty);
      await _tap(tester, '计算剩余价值');
      expect(f.native.calculations, isEmpty);
    },
  );

  _testMac(
    'revision and owner changes both retire the previous account drafts',
    (tester) async {
      final f = await _mount(tester);
      await _fill(tester, _amount, 'Private account one input');
      await _fill(tester, _asking, '81');
      f.state.changeIdentity(owner: 2, advanceRevision: false);
      await _frames(tester);
      expect(await _text(tester, _amount), isEmpty);
      expect(await _text(tester, _asking), isEmpty);
      await _fill(tester, _amount, '25');
      f.state.changeIdentity(owner: 2);
      await _frames(tester);
      expect(await _text(tester, _amount), isEmpty);
      await f.show(tester, topic: '17', remount: true);
      expect(await _text(tester, _amount), isEmpty);
      f.state.changeIdentity(owner: 1, advanceRevision: false);
      await _frames(tester);
      expect(await _text(tester, _amount), isEmpty);
      expect(f.native.calculations, isEmpty);
    },
  );

  _testMac(
    'title hints wait for an explicit click and retain unrelated inputs',
    (tester) async {
      final f = await _mount(tester, title: 'Fixture title with renewal');
      expect(f.native.hints, hasLength(1));
      expect(
        f.native.hints.single.arguments['title'],
        'Fixture title with renewal',
      );
      await _fill(tester, _amount, '12');
      await _validDates(tester);
      await _fill(tester, _asking, '180');
      f.native.hints.single.completion.complete({
        'available': true,
        'amount': '35.99',
        'base': 'JPY',
        'cycle': 12,
      });
      await _frames(tester);
      expect(await _text(tester, _amount), '12');
      await _reveal(tester, _selector('月付'));
      expect(
        tester.widget<GlassSegmentedControl>(_selector('月付')).selectedIndex,
        0,
      );
      await _tap(tester, '从标题带入');
      expect(await _text(tester, _amount), '35.99');
      await _reveal(tester, _button('JPY'));
      expect(_button('JPY'), findsOneWidget);
      await _reveal(tester, _selector('月付'));
      expect(
        tester.widget<GlassSegmentedControl>(_selector('月付')).selectedIndex,
        3,
      );
      expect(await _text(tester, _asOf), '2027-01-01');
      expect(await _text(tester, _expires), '2027-07-03');
      expect(await _text(tester, _asking), '180');
      expect(f.native.calculations, isEmpty);
    },
  );

  _testMac('late hints cannot cross topic or account context boundaries', (
    tester,
  ) async {
    final f = await _mount(tester, title: 'Previous title');
    final previous = f.native.hints.single;
    await f.show(tester, topic: '42', title: 'Current title');
    expect(f.native.hints, hasLength(2));
    final current = f.native.hints.last;
    previous.completion.complete({
      'available': true,
      'amount': '111',
      'base': 'JPY',
      'cycle': 36,
    });
    await _frames(tester);
    expect(await _text(tester, _amount), isEmpty);
    await _reveal(tester, find.text('Current title'));
    final staleButtons = tester.widgetList<DeskButton>(_button('从标题带入'));
    expect(staleButtons.where((button) => button.onTap != null), isEmpty);
    current.completion.complete({
      'available': true,
      'amount': '42',
      'base': 'USD',
      'cycle': 3,
    });
    await _frames(tester);
    await _reveal(tester, _button('从标题带入'));
    final oldApply = tester.widget<DeskButton>(_button('从标题带入')).onTap!;
    f.state.changeIdentity(owner: 2);
    await _frames(tester);
    oldApply();
    await _frames(tester);
    expect(await _text(tester, _amount), isEmpty);
    expect(f.native.calculations, isEmpty);
  });

  _testMac('blank titles do not request a hint or invent a renewal amount', (
    tester,
  ) async {
    final f = await _mount(tester, title: '  ');
    expect(f.native.hints, isEmpty);
    expect(await _text(tester, _amount), isEmpty);
    await f.show(tester, topic: '42');
    expect(f.native.hints, isEmpty);
  });

  _testMac(
    'calculation date rejects normalized invalid input and sends civil milliseconds',
    (tester) async {
      final before = DateTime.now();
      final f = await _mount(tester);
      final after = DateTime.now();
      String dateLabel(DateTime date) =>
          '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}';
      expect(
        await _text(tester, _asOf),
        isIn([dateLabel(before), dateLabel(after)]),
      );
      await _fill(tester, _amount, '35.99');
      await _fill(tester, _expires, '2029-01-01');
      for (final invalid in ['', '2027-02-30', '0000-01-01', '2027-1-01']) {
        await _fill(tester, _asOf, invalid);
        await _tap(tester, '计算剩余价值');
        expect(f.native.calculations, isEmpty);
        await _reveal(tester, find.text('请输入有效的计算日期，例如 2027-01-01。'));
        expect(find.text('请输入有效的计算日期，例如 2027-01-01。'), findsOneWidget);
        expect(await _text(tester, _asOf), invalid);
      }
      await _fill(tester, _asOf, '2028-02-29');
      await _tap(tester, '计算剩余价值');
      final args = f.native.calculations.single.arguments;
      expect(args['asOf'], isA<double>());
      expect(
        args['asOf'],
        DateTime(2028, 2, 29).millisecondsSinceEpoch.toDouble(),
      );
      expect(
        args['expires'],
        DateTime(2029, 1, 1).millisecondsSinceEpoch.toDouble(),
      );
    },
  );

  _testMac(
    'copy uses the accepted complete snapshot and becomes unavailable after editing',
    (tester) async {
      final f = await _mount(tester, title: 'Fixture renewal topic');
      f.native.hints.single.completion.complete({'available': false});
      await _fill(tester, _amount, '35.99');
      await _validDates(tester);
      await _select(tester, '月付', 3);
      await _select(tester, '自动汇率', 1);
      await _fill(tester, '1 USD 等于多少 CNY', '7.25');
      await _fill(tester, _asking, '180');
      await _tap(tester, '计算剩余价值');
      final request = f.native.calculations.single;
      request.completion.complete(_result(request));
      await _frames(tester);
      await _reveal(tester, _button('复制结果'));
      final staleCopy = tester.widget<DeskButton>(_button('复制结果')).onTap!;
      await _tap(tester, '复制结果');
      expect(f.clipboard, hasLength(1));
      final copied = f.clipboard.single;
      for (final part in [
        'Fixture renewal topic',
        '35.99',
        'USD',
        'CNY',
        '12 个月',
        '2027-01-01',
        '2027-07-03',
        '7.25',
        '手动汇率',
        '17.995',
        '130.46',
        '183',
        '180',
        '溢价',
        '49.54',
      ]) {
        expect(
          copied,
          contains(part),
          reason: 'Missing snapshot detail: $part',
        );
      }
      await _fill(tester, _amount, '99');
      expect(find.text('估算结果'), findsNothing);
      expect(_button('复制结果'), findsNothing);
      staleCopy();
      await _frames(tester);
      expect(f.clipboard, [copied]);
    },
  );

  _testMac(
    'selection and caret changes retain the accepted result while text edits invalidate it',
    (tester) async {
      final f = await _mount(tester);
      await _fill(tester, _amount, '35.99');
      await _validDates(tester);
      await _select(tester, '自动汇率', 1);
      await _fill(tester, '1 USD 等于多少 CNY', '7.25');
      await _fill(tester, _asking, '180');
      await _tap(tester, '计算剩余价值');
      final request = f.native.calculations.single;
      request.completion.complete(_result(request));
      await _frames(tester);
      await _tap(tester, '复制结果');
      final acceptedCopy = f.clipboard.single;

      for (final placeholder in [
        _amount,
        _expires,
        _asOf,
        '1 USD 等于多少 CNY',
        _asking,
      ]) {
        final field = _field(placeholder);
        await _reveal(tester, field);
        final input = tester.widget<CupertinoTextField>(field).controller!;
        final originalText = input.text;
        input.selection = TextSelection(
          baseOffset: 0,
          extentOffset: originalText.length,
        );
        await _frames(tester);
        input.selection = const TextSelection.collapsed(offset: 1);
        await _frames(tester);
        expect(input.text, originalText);
        await _tap(tester, '复制结果');
        expect(f.clipboard.last, acceptedCopy);
        expect(f.native.calculations, hasLength(1));
      }
      expect(f.clipboard, hasLength(6));
      await _fill(tester, _amount, '36.99');
      expect(find.text('估算结果'), findsNothing);
      expect(_button('复制结果'), findsNothing);
      expect(f.clipboard, everyElement(acceptedCopy));
      expect(f.native.calculations, hasLength(1));
    },
  );

  for (final title in <String?>[null, 'Fixture title with retained form']) {
    _testMac(
      'result insertion and removal retain the active input connection ${title == null ? 'without' : 'with'} a title',
      (tester) async {
        final f = await _mount(
          tester,
          title: title,
          size: const Size(1100, 1300),
        );
        if (title != null) {
          f.native.hints.single.completion.complete({'available': false});
          await _frames(tester);
        }
        await _validDates(tester);
        final field = _field(_amount);
        await _reveal(tester, field);
        await tester.showKeyboard(field);
        const initial = TextEditingValue(
          text: '35.99',
          selection: TextSelection.collapsed(offset: 5),
        );
        tester.testTextInput.updateEditingValue(initial);
        await _frames(tester);

        final fieldElement = tester.element(field);
        final controller = tester.widget<CupertinoTextField>(field).controller!;
        final editor = find.descendant(
          of: field,
          matching: find.byType(EditableText),
        );
        final editorState = tester.state<EditableTextState>(editor);
        final focus = tester.widget<EditableText>(editor).focusNode;
        void expectRetained(TextEditingValue value) {
          expect(tester.element(field), same(fieldElement));
          expect(
            tester.widget<CupertinoTextField>(field).controller,
            same(controller),
          );
          expect(tester.state<EditableTextState>(editor), same(editorState));
          expect(tester.widget<EditableText>(editor).focusNode, same(focus));
          expect(focus.hasFocus, true);
          expect(controller.value, value);
        }

        // Invoke the existing action without introducing a deliberate mouse
        // focus change. After this point, input always uses the same platform
        // connection; enterText/showKeyboard must not conceal a rebuilt editor.
        tester.widget<DeskButton>(_button('计算剩余价值')).onTap!();
        await _frames(tester);
        final first = f.native.calculations.single;
        expectRetained(initial);
        first.completion.complete(_result(first));
        await _frames(tester);
        expect(find.text('估算结果'), findsOneWidget);
        expectRetained(initial);

        final composing = <TextEditingValue>[
          for (final text in ['35.991', '35.9912', '35.99123'])
            TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: text.length),
              composing: TextRange(start: 5, end: text.length),
            ),
        ];
        for (final value in composing) {
          tester.testTextInput.updateEditingValue(value);
          await _frames(tester);
          expectRetained(value);
          expect(find.text('估算结果'), findsNothing);
          expect(_button('复制结果'), findsNothing);
          expect(f.native.calculations, hasLength(1));
        }
        final committed = composing.last.copyWith(composing: TextRange.empty);
        tester.testTextInput.updateEditingValue(committed);
        await _frames(tester);
        expectRetained(committed);
        tester.widget<DeskButton>(_button('计算剩余价值')).onTap!();
        await _frames(tester);
        expect(f.native.calculations, hasLength(2));
        final second = f.native.calculations.last;
        expect(second.arguments['amount'], committed.text);
        second.completion.complete(_result(second));
        await _frames(tester);
        expect(find.text('估算结果'), findsOneWidget);
        expectRetained(committed);
        const continued = TextEditingValue(
          text: '35.991234',
          selection: TextSelection.collapsed(offset: 9),
        );
        tester.testTextInput.updateEditingValue(continued);
        await _frames(tester);
        expectRetained(continued);
        expect(find.text('估算结果'), findsNothing);
      },
    );
  }

  final decimalRates = [
    '0.12345678901234567890123456789012345678',
    '0.${List.filled(100, '0').join()}1234567890123456789012345678',
  ];
  for (final decimal in decimalRates) {
    _testMac(
      'automatic native Decimal with ${decimal.split('.').last.length} fractional places remains an exact wire string',
      (tester) async {
        final f = await _mount(
          tester,
          rateResponse: {
            'base': 'USD',
            'quote': 'CNY',
            'rate': decimal,
            'source': 'Exact Decimal fixture',
          },
        );
        await _reveal(tester, find.text('1 USD = $decimal CNY'));
        expect(find.text('1 USD = $decimal CNY'), findsOneWidget);
        await _fill(tester, _amount, '35.99');
        await _validDates(tester);
        await _tap(tester, '计算剩余价值');
        final request = f.native.calculations.single;
        expect(request.arguments['rate'], isA<String>());
        expect(request.arguments['rate'], decimal);
        request.completion.complete(_result(request, formatted: '0.00 CNY'));
        await _frames(tester);
        await _tap(tester, '复制结果');
        expect(f.clipboard.single, contains('1 USD = $decimal CNY'));
        expect(f.clipboard.single, contains('Exact Decimal fixture'));
      },
    );
  }

  for (final mismatched in const [
    {'base': 'JPY', 'quote': 'CNY'},
    {'base': 'USD', 'quote': 'JPY'},
  ]) {
    _testMac(
      'explicitly mismatched ${mismatched['base']}/${mismatched['quote']} rate is rejected while original value remains usable',
      (tester) async {
        final f = await _mount(
          tester,
          rateResponse: {
            ...mismatched,
            'rate': '91.7',
            'source': 'Wrong currency pair fixture',
          },
        );
        await _reveal(tester, find.text('尚未取得汇率，可先计算原币估值。'));
        expect(find.text('1 USD = 91.7 CNY'), findsNothing);
        await _fill(tester, _amount, '35.99');
        await _validDates(tester);
        await _fill(tester, _asking, '180');
        await _tap(tester, '计算剩余价值');
        final request = f.native.calculations.single;
        expect(request.arguments['base'], 'USD');
        expect(request.arguments['quote'], 'CNY');
        expect(request.arguments.containsKey('rate'), false);
        expect(request.arguments.containsKey('asking'), false);
        request.completion.complete({
          'amount': '18.5',
          'days': 183,
          'fullCycles': 6,
          'partialDays': 2,
          'partialCycleDays': 31,
        });
        await _frames(tester);
        await _reveal(tester, find.text('18.5 USD'));
        expect(find.text('原币剩余价值'), findsOneWidget);
        expect(find.text('18.5 USD'), findsOneWidget);
        expect(await _text(tester, _amount), '35.99');
        expect(await _text(tester, _asking), '180');
      },
    );
  }

  _testMac('legacy rate replies without currency keys remain accepted', (
    tester,
  ) async {
    final f = await _mount(
      tester,
      rateResponse: const {'rate': '7.15', 'source': 'Legacy fixture rate'},
    );
    await _reveal(tester, find.text('1 USD = 7.15 CNY'));
    expect(find.text('1 USD = 7.15 CNY'), findsOneWidget);
    await _fill(tester, _amount, '35.99');
    await _validDates(tester);
    await _fill(tester, _asking, '180');
    await _tap(tester, '计算剩余价值');
    final request = f.native.calculations.single;
    expect(request.arguments['rate'], '7.15');
    expect(request.arguments['asking'], '180');
  });

  _testMac(
    'editing while a calculation is pending prevents a stale result or copy action',
    (tester) async {
      final f = await _mount(tester);
      await _fill(tester, _amount, '35.99');
      await _validDates(tester);
      await _tap(tester, '计算剩余价值');
      final pending = f.native.calculations.single;
      await _fill(tester, _asOf, '2027-02-01');
      pending.completion.complete(_result(pending));
      await _frames(tester);
      expect(find.text('估算结果'), findsNothing);
      expect(_button('复制结果'), findsNothing);
      expect(tester.widget<DeskButton>(_button('计算剩余价值')).busy, false);
      expect(await _text(tester, _asOf), '2027-02-01');
      expect(f.clipboard, isEmpty);
    },
  );

  _testMac(
    'a late calculation cannot install or copy a previous topic snapshot',
    (tester) async {
      final f = await _mount(tester);
      await _fill(tester, _amount, '17');
      await _validDates(tester);
      await _tap(tester, '计算剩余价值');
      final previous = f.native.calculations.single;
      await f.show(tester, topic: '42');
      await _fill(tester, _amount, '42');
      await _validDates(tester);
      await _tap(tester, '计算剩余价值');
      final current = f.native.calculations.last;
      expect(f.native.calculations, hasLength(2));
      previous.completion.complete(
        _result(previous, formatted: 'Previous topic result'),
      );
      await _frames(tester);
      expect(find.text('Previous topic result'), findsNothing);
      expect(_button('复制结果'), findsNothing);
      expect(tester.widget<DeskButton>(_button('计算剩余价值')).busy, true);
      current.completion.complete(
        _result(current, formatted: 'Current topic result'),
      );
      await _frames(tester);
      await _reveal(tester, find.text('Current topic result'));
      expect(find.text('Current topic result'), findsOneWidget);
      await _fill(tester, _expires, '2027-08-03');
      expect(find.text('Current topic result'), findsNothing);
      expect(_button('复制结果'), findsNothing);
      expect(f.clipboard, isEmpty);
    },
  );

  _testMac(
    'short narrow embedded pane keeps fixed actions and every field reachable',
    (tester) async {
      const size = Size(360, 520);
      final f = await _mount(tester, size: size, scale: 1.5);
      final close = _icon('关闭估价');
      final calculate = _button('计算剩余价值');
      expect(close.hitTestable(), findsOneWidget);
      expect(calculate.hitTestable(), findsOneWidget);
      final headerPosition = tester.getRect(close);
      final footerPosition = tester.getRect(calculate);
      await _fill(tester, _amount, '35.99');
      await _validDates(tester);
      await _select(tester, '月付', 3);
      await _select(tester, '自动汇率', 1);
      await _fill(tester, '1 USD 等于多少 CNY', '7.25');
      await _fill(tester, _asking, '180');
      expect(tester.getRect(close), headerPosition);
      expect(tester.getRect(calculate), footerPosition);
      expect(close.hitTestable(), findsOneWidget);
      expect(calculate.hitTestable(), findsOneWidget);
      for (final bounds in [headerPosition, footerPosition]) {
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(size.width));
        expect(bounds.top, greaterThanOrEqualTo(0));
        expect(bounds.bottom, lessThanOrEqualTo(size.height));
      }
      await tester.tap(calculate);
      await _frames(tester);
      final args = f.native.calculations.single.arguments;
      expect(args['amount'], '35.99');
      expect(args['cycle'], 12);
      expect(args['rate'], '7.25');
      expect(args['asking'], '180');
      expect(tester.takeException(), isNull);
    },
  );
}
