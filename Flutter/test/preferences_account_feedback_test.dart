import 'dart:async';
import 'dart:ui' show SemanticsAction;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/account_screen.dart';
import 'package:seekdesk_flutter/screens/preferences_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/glass_chrome.dart';
import 'package:seekdesk_flutter/widgets/node_image_settings.dart';

class FeedbackFixture extends NativeClient {
  final calls = <(String, JsonMap)>[];
  Future<JsonMap> Function(String, JsonMap)? response;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    calls.add((method, {...arguments}));
    return await response?.call(method, arguments) ?? {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> mount(WidgetTester tester, Widget screen) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      GlassAdaptiveScope(
        minQuality: GlassQuality.minimal,
        maxQuality: GlassQuality.minimal,
        child: CupertinoApp(home: CupertinoPageScaffold(child: screen)),
      ),
    );
    await tester.pump();
  }

  Future<void> cleanup(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    await tester.pump(const Duration(seconds: 6));
  }

  Finder button(String label) => find.byWidgetPredicate(
    (widget) => widget is DeskButton && widget.label == label,
  );

  testWidgets(
    'general preferences open the shared image settings once and permit reopening',
    (tester) async {
      final native = FeedbackFixture();
      native.response = (method, args) async =>
          method == 'images.keyStatus' ? {'configured': true} : {};
      final state = AppState(client: native);
      await mount(tester, PreferencesScreen(state: state));
      expect(find.text('通用功能'), findsOneWidget);
      final open = tester.widget<DeskButton>(button('图床设置')).onTap!;
      await tester.tap(button('图床设置'));
      await tester.pumpAndSettle();
      open();
      await tester.pump();
      expect(find.byType(NodeImageSettings), findsOneWidget);
      expect(
        native.calls.where((call) => call.$1 == 'images.keyStatus'),
        hasLength(1),
      );
      expect(
        native.calls.where(
          (call) => const {
            'images.setKey',
            'images.removeKey',
            'system.chooseImage',
          }.contains(call.$1),
        ),
        isEmpty,
      );
      await tester.tap(button('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(NodeImageSettings), findsNothing);
      await tester.tap(button('图床设置'));
      await tester.pumpAndSettle();
      expect(
        native.calls.where((call) => call.$1 == 'images.keyStatus'),
        hasLength(2),
      );
      await cleanup(tester, state);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'preference sliders announce names and real point values and persist accessibility adjustments',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final native = FeedbackFixture();
      final state = AppState(client: native);
      var settings = <String, dynamic>{'workspace.sidebarWidth': 250.0};
      native.response = (method, args) async {
        if (method == 'settings.update') {
          settings = {...settings, stringValue(args['key']): args['value']};
        }
        return {...settings};
      };
      await mount(tester, PreferencesScreen(state: state));
      await tester.tap(find.text('外观'));
      await tester.pump();
      final slider = find.byKey(
        const ValueKey('preference-slider-workspace.sidebarWidth'),
      );
      final node = tester.getSemantics(slider);
      var data = node.getSemanticsData();
      expect(data.label, '侧边栏宽度');
      expect(data.value, '250 点');
      expect(data.increasedValue, '251 点');
      expect(data.decreasedValue, '249 点');
      expect(data.hasAction(SemanticsAction.increase), isTrue);
      expect(find.bySemanticsLabel('Slider'), findsNothing);
      tester
          .renderObject(slider)
          .owner!
          .semanticsOwner!
          .performAction(node.id, SemanticsAction.increase);
      await tester.pump();
      data = tester.getSemantics(slider).getSemanticsData();
      expect(data.value, '251 点');
      expect(
        native.calls.where((call) => call.$1 == 'settings.update').single.$2,
        {'key': 'workspace.sidebarWidth', 'value': 251.0},
      );
      await cleanup(tester, state);
      semantics.dispose();
    },
  );

  testWidgets(
    'reading sliders expose actual percent and stop increasing at the limit',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final native = FeedbackFixture();
      final state = AppState(client: native);
      var settings = <String, dynamic>{'workspace.nqReportScale': 200.0};
      state.domains['settings'] = settings;
      native.response = (method, args) async {
        if (method == 'settings.update') {
          settings = {...settings, stringValue(args['key']): args['value']};
        }
        return {...settings};
      };
      await mount(tester, PreferencesScreen(state: state));
      await tester.tap(find.text('阅读'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final slider = find.byKey(
        const ValueKey('preference-slider-workspace.nqReportScale'),
      );
      await tester.ensureVisible(slider);
      await tester.pump();
      final node = tester.getSemantics(slider);
      final data = node.getSemanticsData();
      expect(data.label, 'NQ 显示比例');
      expect(data.value, '200%');
      expect(data.decreasedValue, '199%');
      expect(data.hasAction(SemanticsAction.increase), isFalse);
      expect(data.hasAction(SemanticsAction.decrease), isTrue);
      tester
          .renderObject(slider)
          .owner!
          .semanticsOwner!
          .performAction(node.id, SemanticsAction.decrease);
      await tester.pump();
      expect(tester.getSemantics(slider).getSemanticsData().value, '199%');
      expect(state.domain('settings')['workspace.nqReportScale'], 199.0);
      await cleanup(tester, state);
      semantics.dispose();
    },
  );

  testWidgets(
    'only the focused slider handles arrows with one Tab stop and bounded values',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final native = FeedbackFixture();
      final state = AppState(client: native);
      var settings = <String, dynamic>{
        'workspace.sidebarWidth': 250.0,
        'workspace.topicColumnWidth': 340.0,
      };
      native.response = (method, args) async {
        if (method == 'settings.update') {
          settings = {...settings, stringValue(args['key']): args['value']};
        }
        return {...settings};
      };
      await mount(tester, PreferencesScreen(state: state));
      await tester.tap(find.text('外观'));
      await tester.pump();
      final sidebar = find.byKey(
        const ValueKey('preference-slider-workspace.sidebarWidth'),
      );
      final topic = find.byKey(
        const ValueKey('preference-slider-workspace.topicColumnWidth'),
      );
      FocusNode sliderFocus(Finder scope) => tester
          .widget<GlassSlider>(
            find.descendant(of: scope, matching: find.byType(GlassSlider)),
          )
          .focusNode!;
      Iterable<(String, JsonMap)> writes() =>
          native.calls.where((call) => call.$1 == 'settings.update');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(writes(), isEmpty);

      sliderFocus(sidebar).requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, sliderFocus(sidebar));
      for (final key in [
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowDown,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pump();
      }
      expect(writes().map((call) => call.$2['value']), [
        251.0,
        252.0,
        251.0,
        250.0,
      ]);
      expect(tester.getSemantics(sidebar).getSemanticsData().value, '250 点');
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(state.domain('settings')['workspace.sidebarWidth'], 184.0);
      final writesAtMin = writes().length;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(writes().length, writesAtMin);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(state.domain('settings')['workspace.sidebarWidth'], 360.0);
      final writesAtMax = writes().length;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(writes().length, writesAtMax);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus,
        sliderFocus(topic),
        reason: 'One Tab must move directly to the next slider.',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(state.domain('settings')['workspace.sidebarWidth'], 360.0);
      expect(state.domain('settings')['workspace.topicColumnWidth'], 339.0);
      expect(writes().last.$2['key'], 'workspace.topicColumnWidth');
      expect(find.bySemanticsLabel('Slider'), findsNothing);
      await cleanup(tester, state);
      semantics.dispose();
    },
  );

  testWidgets(
    'signed-in empty profile offers retry and the retry can recover',
    (tester) async {
      final native = FeedbackFixture();
      final state = AppState(client: native);
      state.domains['session'] = {'account': 'signedIn', 'owner': 1};
      var loads = 0;
      native.response = (method, args) async {
        if (method == 'profile.load') {
          loads++;
          return {
            'account': 'signedIn',
            if (loads > 1)
              'profile': {'id': 1, 'name': 'Recovered owner', 'avatar': ''},
          };
        }
        return {'kind': 'failed'};
      };
      await mount(tester, AccountScreen(state: state));
      expect(button('重试加载'), findsOneWidget);
      expect(button('登录 NodeSeek'), findsNothing);
      await tester.tap(button('重试加载'));
      await tester.pump();
      expect(find.text('Recovered owner'), findsOneWidget);
      expect(
        native.calls
            .where((call) => call.$1 == 'profile.load')
            .last
            .$2['force'],
        isTrue,
      );
      expect(native.calls.any((call) => call.$1 == 'session.signIn'), isFalse);
      await cleanup(tester, state);
    },
  );

  testWidgets('signed-in native profile error retains a persistent retry', (
    tester,
  ) async {
    final native = FeedbackFixture();
    final state = AppState(client: native);
    state.domains['session'] = {'account': 'signedIn', 'owner': 1};
    native.response = (method, args) async {
      if (method == 'profile.load') {
        throw const NativeFailure('native_error', 'fixture timeout');
      }
      return {'kind': 'failed'};
    };
    await mount(tester, AccountScreen(state: state));
    await tester.pump(const Duration(seconds: 6));
    expect(button('重试加载'), findsOneWidget);
    expect(find.text('暂时无法读取账号资料，请检查网络后重试。'), findsOneWidget);
    expect(button('登录 NodeSeek'), findsNothing);
    await cleanup(tester, state);
  });

  testWidgets(
    'signed-out own profile uses the actual returned session condition',
    (tester) async {
      final native = FeedbackFixture();
      final state = AppState(client: native);
      state.domains['session'] = {'account': 'signedIn', 'owner': 1};
      native.response = (method, args) async => {'account': 'signedOut'};
      await mount(tester, AccountScreen(state: state));
      expect(button('登录 NodeSeek'), findsOneWidget);
      expect(button('重试加载'), findsNothing);
      await tester.tap(button('登录 NodeSeek'));
      await tester.pump();
      expect(
        native.calls.where((call) => call.$1 == 'session.signIn'),
        hasLength(1),
      );
      await cleanup(tester, state);
    },
  );

  testWidgets(
    'unconfirmed own access offers verification and a separate retry',
    (tester) async {
      final native = FeedbackFixture();
      final state = AppState(client: native);
      state.domains['session'] = {'account': 'unconfirmed'};
      native.response = (method, args) async => {'account': 'unconfirmed'};
      await mount(tester, AccountScreen(state: state));
      expect(button('验证访问'), findsOneWidget);
      expect(button('重试加载'), findsOneWidget);
      expect(button('登录 NodeSeek'), findsNothing);
      expect(
        find.text('尚未确认 NodeSeek 的访问状态。可打开站点确认访问，再重新加载资料。'),
        findsOneWidget,
      );
      await tester.tap(button('验证访问'));
      await tester.pump();
      expect(
        native.calls.where((call) => call.$1 == 'session.verify').single.$2,
        {'url': 'https://www.nodeseek.com/'},
      );
      await cleanup(tester, state);
    },
  );

  testWidgets(
    'confirmed native verification result does not offer account login',
    (tester) async {
      final native = FeedbackFixture();
      final state = AppState(client: native);
      state.domains['session'] = {'account': 'signedIn', 'owner': 1};
      native.response = (method, args) async => method == 'profile.introduction'
          ? {'kind': 'verification'}
          : {'account': 'signedIn'};
      await mount(tester, AccountScreen(state: state));
      expect(button('验证访问'), findsOneWidget);
      expect(find.text('请在 NodeSeek 窗口中完成站点验证，然后重新加载资料。'), findsOneWidget);
      expect(button('登录 NodeSeek'), findsNothing);
      await cleanup(tester, state);
    },
  );

  testWidgets('a failed public profile remains retryable for a guest', (
    tester,
  ) async {
    final native = FeedbackFixture();
    final state = AppState(client: native);
    state.domains['session'] = {'account': 'signedOut'};
    native.response = (method, args) async => {
      'owner': null,
      'accessRevision': 0,
    };
    await mount(tester, AccountScreen(state: state, memberId: 42));
    expect(button('重试加载'), findsOneWidget);
    expect(button('登录 NodeSeek'), findsNothing);
    await cleanup(tester, state);
  });

  testWidgets('an identity change cannot apply stale recovery guidance', (
    tester,
  ) async {
    final native = FeedbackFixture();
    final state = AppState(client: native);
    state.domains['session'] = {'account': 'signedOut'};
    final pending = Completer<JsonMap>();
    var loads = 0;
    native.response = (method, args) async {
      if (method == 'profile.load') {
        loads++;
        if (loads == 1) return pending.future;
        return {'account': 'signedIn', 'accessRevision': 1};
      }
      return {'kind': 'failed'};
    };
    await mount(tester, AccountScreen(state: state));
    native.accessRevision = 1;
    state.domains['session'] = {'account': 'signedIn', 'owner': 2};
    state.showMessage('Fixture identity update');
    pending.complete({'account': 'signedOut', 'accessRevision': 0});
    await tester.pump();
    expect(loads, 2);
    expect(button('重试加载'), findsOneWidget);
    expect(button('登录 NodeSeek'), findsNothing);
    await cleanup(tester, state);
  });
}
