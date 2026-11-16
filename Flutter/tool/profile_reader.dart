// Local performance entry point only. The ordinary lib/main.dart never imports
// this fixture. Build through scripts/build-macos.sh with the fixture flag so
// the native host also excludes every real service and persisted account.
import 'dart:async';
import 'dart:convert';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:seekdesk_flutter/core/frame_diagnostics.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/main.dart' show WorkspaceScreen;
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/extension_overlays.dart';
import 'package:seekdesk_flutter/widgets/edit_menu_bridge.dart';

import 'fixture_keyboard_diagnostics.dart';
import 'editor_fixture.dart';

const profileFixtureID = 'reader-nq250-replies25-v1';
const profileFixtureURL = 'https://fixture.seekdesk.invalid/post-7001-1';

Future<void> main() async {
  if (!const bool.fromEnvironment('SEEKDESK_PROFILE_FIXTURE')) {
    throw StateError(
      'Use SEEKDESK_PROFILE_FIXTURE=1 scripts/build-macos.sh profile.',
    );
  }
  WidgetsFlutterBinding.ensureInitialized();
  FixtureKeyboardDiagnostics.start();
  PaintingBinding.instance.imageCache.maximumSize = 64;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 24 * 1024 * 1024;
  final initializing = Stopwatch()..start();
  await LiquidGlassWidgets.initialize();
  debugPrintSynchronously(
    jsonEncode({
      'seekdeskDiagnostics': 'localFixture',
      'fixtureID': const bool.fromEnvironment('SEEKDESK_EDITOR_FIXTURE')
          ? 'editor-media-lifecycle-v1'
          : profileFixtureID,
      'source': 'synthetic memory only; no forum or user content',
      'terminalRows': const bool.fromEnvironment('SEEKDESK_EDITOR_FIXTURE')
          ? 0
          : 250,
      'replies': const bool.fromEnvironment('SEEKDESK_EDITOR_FIXTURE') ? 0 : 25,
      'glassInitializeMs': initializing.elapsedMicroseconds / 1000,
      'sharedBackdropEnabled': const bool.fromEnvironment(
        'SEEKDESK_SHARED_BACKDROP',
        defaultValue: true,
      ),
    }),
  );
  FrameDiagnostics.start();
  runApp(const ProfileReaderApp());
}

/// The real workspace and reader, with the same pinned premium glass theme.
class ProfileReaderApp extends StatefulWidget {
  const ProfileReaderApp({super.key});

  @override
  State<ProfileReaderApp> createState() => _ProfileReaderAppState();
}

class _ProfileReaderAppState extends State<ProfileReaderApp> {
  late final AppState state;

  @override
  void initState() {
    super.initState();
    state = AppState(
      client: const bool.fromEnvironment('SEEKDESK_EDITOR_FIXTURE')
          ? MemoryEditorClient()
          : MemoryProfileClient(),
    );
    state.registerDraftFlusher('benchmark-diagnostics', () async {
      await FrameDiagnostics.flush();
      return true;
    });
    unawaited(state.connect());
  }

  @override
  void dispose() {
    FixtureKeyboardDiagnostics.stop();
    state.dispose();
    FrameDiagnostics.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LiquidGlassWidgets.wrap(
    theme: GlassThemeData.ios27(brightness: Brightness.light),
    child: CupertinoApp(
      title: 'SeekDesk Benchmark · 本地夹具',
      debugShowCheckedModeBanner: false,
      builder: (context, child) => EditMenuBridge(
        child: ExtensionOverlays(
          state: state,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
      theme: const CupertinoThemeData(
        brightness: Brightness.light,
        primaryColor: Color(0xff4263df),
        textTheme: CupertinoTextThemeData(
          textStyle: TextStyle(
            fontSize: 14,
            height: 1.45,
            color: Color(0xff26314a),
          ),
        ),
      ),
      home: const bool.fromEnvironment('SEEKDESK_EDITOR_FIXTURE')
          ? EditorFixtureHome(state: state)
          : WorkspaceScreen(state: state),
    ),
  );
}

/// No call, including an unknown button action, can reach the native client.
/// The inherited method channel is used only for the host's inbound quit/flush
/// handshake installed by AppState. No event channel subscription is made.
class MemoryProfileClient extends NativeClient {
  final JsonMap _settings = {
    'appearance': 'light',
    'workspace.sidebarWidth': 200,
    'workspace.topicColumnWidth': 320,
    'workspace.hideListWhileReading': false,
    'workspace.autoLoadOlder': false,
    'workspace.mistBackdrop': true,
    'workspace.readingDensity': 'comfortable',
    'workspace.boardTextSize': 13,
    'workspace.readerTextSize': 15,
    'workspace.floorAuthorScale': 100,
    'workspace.nqReportScale': 100,
  };
  final Map<String, double> _positions = {};
  late final List<JsonMap> _posts = List.generate(
    18,
    (index) => {
      'id': '${7001 + index}',
      'url': 'https://fixture.seekdesk.invalid/post-${7001 + index}-1',
      'title': index == 0
          ? '本地性能夹具 · NQ 250 行与 25 条回复'
          : '本地示例 ${index + 1} · 阅读与玻璃工具栏',
      'author': '本地作者 ${index % 6 + 1}',
      'category': index.isEven ? '技术' : '日常',
      'dateLabel': '11/14 12:00',
      'summary': '固定生成的性能测试内容，不来自论坛或用户数据。',
    },
  );
  late List<JsonMap> _tabs = _posts.take(3).toList();
  List<JsonMap> _closedTabs = [];
  String _selected = '7001';
  bool _showReader = true;
  String _board = 'home';
  late final JsonMap _thread = _makeThread();

  @override
  Stream<JsonMap> get snapshots => const Stream<JsonMap>.empty();

  JsonMap _workspace() => {
    'posts': [..._posts],
    'tabs': [..._tabs],
    'closedTabs': [..._closedTabs],
    'selectedTab': _selected,
    'showReader': _showReader,
    'board': _board,
    'loading': false,
    'canLoadOlder': false,
    'boards': [
      {'id': 'home', 'title': '首页'},
      {'id': 'tech', 'title': '技术'},
      {'id': 'daily', 'title': '日常'},
      {'id': 'trade', 'title': '交易'},
      {'id': 'review', 'title': '测评'},
    ],
  };

  JsonMap _reader(String url) => {
    'url': url,
    'loading': false,
    'scrollOffset': _positions[url] ?? 0,
    'thread': _thread,
  };

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    switch (method) {
      case 'bootstrap':
        return {
          'session': {
            'account': 'signedIn',
            'owner': 900001,
            'accessRevision': 0,
            'profile': {'name': '本地性能夹具', 'id': 900001},
            'canCompose': false,
          },
          'settings': {..._settings},
          'workspace': _workspace(),
          'reader': _reader(profileFixtureURL),
          'extensions': {
            'items': [
              {'id': 'value', 'active': true},
              {'id': 'authorOnly', 'active': true},
            ],
          },
          'proxy': {'enabled': false},
        };
      case 'reader.load':
        return _reader(stringValue(arguments['url'], profileFixtureURL));
      case 'reader.rememberPosition':
        _positions[stringValue(arguments['url'])] = numberValue(
          arguments['offset'],
        );
        return {'saved': true};
      case 'settings.update':
        _settings[stringValue(arguments['key'])] = arguments['value'];
        return {
          'domain': 'settings',
          'data': {..._settings},
          'accessRevision': 0,
        };
      case 'listing.refresh':
      case 'listing.older':
      case 'listing.clearSearch':
        return _workspace();
      case 'listing.selectBoard':
        _board = stringValue(arguments['id'], 'home');
        return _workspace();
      case 'reader.overview':
        _showReader = false;
        return _workspace();
      case 'reader.open':
      case 'reader.select':
        final candidates = _posts.where(
          (post) => method == 'reader.open'
              ? post['url'] == arguments['url']
              : post['id'] == arguments['id'],
        );
        if (candidates.isEmpty) break;
        final topic = candidates.first;
        if (!_tabs.any((tab) => tab['id'] == topic['id'])) _tabs.add(topic);
        _selected = stringValue(topic['id']);
        _showReader = true;
        return _workspace();
      case 'reader.close':
      case 'reader.closeAll':
        final closed = _tabs
            .where(
              (tab) =>
                  method == 'reader.closeAll' || tab['id'] == arguments['id'],
            )
            .toList();
        _closedTabs = [...closed, ..._closedTabs];
        _tabs = _tabs.where((tab) => !closed.contains(tab)).toList();
        if (!_tabs.any((tab) => tab['id'] == _selected)) {
          _selected = _tabs.isEmpty ? '' : stringValue(_tabs.last['id']);
        }
        _showReader = _tabs.isNotEmpty;
        return _workspace();
      case 'reader.reopen':
        final candidates = _closedTabs.where(
          (tab) => arguments['id'] == null || tab['id'] == arguments['id'],
        );
        if (candidates.isEmpty) break;
        final topic = candidates.first;
        _closedTabs.remove(topic);
        _tabs.add(topic);
        _selected = stringValue(topic['id']);
        _showReader = true;
        return _workspace();
      case 'reader.move':
        final from = _tabs.indexWhere((tab) => tab['id'] == arguments['id']);
        final to = _tabs.indexWhere((tab) => tab['id'] == arguments['to']);
        if (from < 0 || to < 0) break;
        _tabs.insert(to, _tabs.removeAt(from));
        return _workspace();
    }
    throw const NativeFailure('fixture_only', '本地性能夹具不执行此操作，也不会连接论坛。');
  }

  JsonMap _makeThread() {
    final rows = List.generate(
      250,
      (index) => <JsonMap>[
        {
          'text': '${(index + 1).toString().padLeft(3, '0')}  ',
          'foreground': '#8392ab',
        },
        {
          'text':
              '${['IPv4 route', 'IPv6 route', 'TCP latency', 'Disk I/O', 'CPU score'][index % 5].padRight(12)} ',
          'foreground': '#82cfff',
          'bold': index % 5 == 0,
        },
        {
          'text': 'fixture-${(index % 20 + 1).toString().padLeft(2, '0')}  ',
          'foreground': '#d6e0f0',
        },
        {
          'text':
              '${(8 + index % 43).toString().padLeft(2)}.${index % 10} ms    ${(90 + index % 10)}%  OK',
          'foreground': '#a7e3b4',
        },
      ],
    );
    return {
      'title': '本地性能夹具 · NQ 250 行与 25 条回复',
      'category': '技术',
      'page': 1,
      'replyRestriction': '仅本机固定夹具 · 不连接论坛',
      'root': {
        'id': '0',
        'author': '本地示例作者',
        'isAuthor': true,
        'dateLabel': '11/14 12:00',
        'likes': 18,
        'chicken': 3,
        'blocks': [
          {'kind': 'notice', 'text': '**本地性能夹具**：全部内容固定生成，不含真实帖子、账号、图片或节点。'},
          {'kind': 'heading', 'text': 'NQ 终端报告与连续阅读'},
          {
            'kind': 'text',
            'text': '这是用于比较相同窗口、刷新率和滚动路径的合成帖子。正文混合中文、English、**加粗**、*强调*与 `inline code`，复用客户端实际 Markdown 和终端渲染组件。',
          },
          {'kind': 'terminal', 'terminal': rows},
          {'kind': 'heading', 'text': '阅读后的讨论'},
          {
            'kind': 'table',
            'rows': [
              ['项目', '固定条件', '用途'],
              ['终端', '250 行', '长内容滚动'],
              ['回复', '25 条', '懒加载与文字布局'],
              ['玻璃', 'Premium', '工具栏折射与交互'],
            ],
          },
          {
            'kind': 'text',
            'text': '以下是固定顺序的普通回复。每次重新启动都回到相同位置；滚动位置和设置修改只保存在本次进程内存中。',
          },
        ],
      },
      'replies': List.generate(
        25,
        (index) => {
          'id': '${index + 1}',
          'author': '本地回复者 ${index % 7 + 1}',
          'isAuthor': index % 7 == 0,
          'dateLabel': '11/14 12:${(index + 1).toString().padLeft(2, '0')}',
          'likes': index % 9,
          'chicken': index % 3,
          'blocks': [
            {
              'kind': 'text',
              'text':
                  '第 ${index + 1} 条固定回复。连续滚动经过多种正文和工具按钮，检查文字清晰度、列表布局与玻璃折射的稳定性。**这些数据仅用于本机性能测量。**',
            },
            if (index % 3 == 0)
              {'kind': 'quote', 'text': '保持窗口大小和滚动路径一致，分别比较首次绘制与后续稳定帧。'},
            if (index % 5 == 0)
              {
                'kind': 'code',
                'text':
                    'fixture: $profileFixtureID\nnetwork: disabled\nterminal_rows: 250\nreplies: 25',
              },
            {
              'kind': 'text',
              'text':
                  'Fixed local content ${index + 1}: renderer measurements include build, raster and total span. 没有网络请求或随机数据影响这段阅读路径。',
            },
          ],
        },
      ),
      'pages': <JsonMap>[],
    };
  }
}
