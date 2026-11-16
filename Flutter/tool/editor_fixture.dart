// Used only by the isolated Profile fixture. Every request remains in memory;
// the native benchmark host does not create forum, account or upload services.
import 'dart:async';
import 'dart:convert';

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:seekdesk_flutter/core/native_client.dart';
import 'package:seekdesk_flutter/screens/composer_screen.dart';
import 'package:seekdesk_flutter/screens/inline_edit_screen.dart';
import 'package:seekdesk_flutter/state/app_state.dart';
import 'package:seekdesk_flutter/widgets/node_image_settings.dart';

const editorFixtureURL = 'https://fixture.seekdesk.invalid/post-8101-1';

class EditorFixtureHome extends StatelessWidget {
  const EditorFixtureHome({required this.state, super.key});
  final AppState state;

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    child: SafeArea(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('编辑器本地夹具', style: TextStyle(fontSize: 26)),
            const SizedBox(height: 14),
            const Text('仅内存数据 · 不连接论坛 · 图片任务模拟等待 10 秒'),
            const SizedBox(height: 24),
            for (final entry in <String, Widget>{
              '新帖编辑器': ComposerScreen(state: state),
              '回复编辑器': ComposerScreen(
                state: state,
                topicID: '8101',
                url: editorFixtureURL,
              ),
              '已有内容编辑器': InlineEditScreen(
                state: state,
                topicID: '8101',
                url: editorFixtureURL,
                floor: 1,
              ),
            }.entries)
              CupertinoButton(
                onPressed: () => Navigator.of(
                  context,
                ).push(CupertinoPageRoute<void>(builder: (_) => entry.value)),
                child: Text(entry.key),
              ),
            CupertinoButton(
              onPressed: () => unawaited(showNodeImageSettings(context, state)),
              child: const Text('图床设置（仅内存）'),
            ),
          ],
        ),
      ),
    ),
  );
}

class MemoryEditorClient extends NativeClient {
  String discussion = '这是本机新帖草稿。\n\n上传测试保留这段正文。';
  String reply = '这是本机回复草稿。\n\n上传测试保留这段正文。';
  String edited = '这是本机已有内容。\n\n本次修改不会连接论坛。';
  String title = '本地编辑器验收';
  String? editToken;
  String editTopic = '';
  int editFloor = 0, editGeneration = 0;
  bool editNeedsVerification = false, editVerificationContinued = false;
  // This synthetic value exists only in this fixture instance. Never use
  // NodeImageKey, a MethodChannel, or a persistent store in the fixture.
  String? _imageKey = 'fixture-only-initial-key';

  JsonMap get editSnapshot => {
    'editToken': editToken,
    'topicID': editTopic,
    'floor': editFloor,
    'accessRevision': accessRevision,
    'ready': editToken != null,
    'saving': false,
    'canSave': !editNeedsVerification,
    'needsVerification': editNeedsVerification,
    'accepted': false,
    'title': title,
    'content': edited,
  };

  @override
  Stream<JsonMap> get snapshots => const Stream<JsonMap>.empty();

  JsonMap get draft => {
    'title': title,
    'content': discussion,
    'category': 'general',
    'rank': 0,
    'ready': true,
    'maxRank': 3,
    'categories': [
      {'id': 'general', 'title': '常规'},
    ],
  };

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) async {
    if (method.startsWith('reader.edit.') && method != 'reader.edit.begin') {
      if (editToken == null ||
          arguments['editToken'] != editToken ||
          arguments['topicID'] != editTopic ||
          arguments['floor'] != editFloor) {
        throw const NativeFailure('stale_editor', '本地夹具的编辑会话已变更。');
      }
    }
    switch (method) {
      case 'bootstrap':
        return {
          'session': {
            'account': 'signedIn',
            'owner': 900001,
            'accessRevision': 0,
            'profile': {'name': '本地编辑器夹具', 'id': 900001},
            'canCompose': true,
          },
          'settings': {'appearance': 'light'},
          'extensions': {'items': []},
        };
      case 'discussion.getDraft':
      case 'discussion.loadOptions':
        return draft;
      case 'discussion.updateDraft':
        title = stringValue(arguments['title'], title);
        discussion = stringValue(arguments['content'], discussion);
        return draft;
      case 'discussion.discard':
        discussion = '';
        return draft;
      case 'reader.replyDraft':
        return {'content': reply};
      case 'reader.updateReplyDraft':
        reply = stringValue(arguments['content'], reply);
        return {'content': reply};
      case 'reader.edit.begin':
        editToken = 'profile-fixture-edit-${++editGeneration}';
        editTopic = stringValue(arguments['topicID']);
        editFloor = intValue(arguments['floor']);
        editNeedsVerification = false;
        editVerificationContinued = false;
        return editSnapshot;
      case 'reader.edit.update':
        title = stringValue(arguments['title'], title);
        edited = stringValue(arguments['content'], edited);
        return editSnapshot;
      case 'reader.edit.cancel':
        final cancelled = {...editSnapshot, 'ready': false};
        editToken = null;
        return cancelled;
      case 'reader.edit.continueVerification':
        editNeedsVerification = false;
        editVerificationContinued = true;
        return editSnapshot;
      case 'session.verify':
        return {'opened': true, 'fixture': true};
      case 'reader.edit.save':
        editNeedsVerification = !editVerificationContinued;
        return {
          ...editSnapshot,
          'message': editNeedsVerification
              ? '本地模拟需要站点验证；验证按钮只操作内存，不连接论坛。'
              : '本地夹具已拦截提交，没有连接论坛。',
        };
      case 'discussion.publish':
      case 'reader.sendReply':
        return {
          'ready': true,
          'accepted': false,
          'message': '本地夹具已拦截提交，没有连接论坛。',
          'content': reply,
        };
      case 'images.keyStatus':
        return {'configured': _imageKey != null};
      case 'images.setKey':
        final key = arguments['key'];
        if (key is! String || nodeImageKeyError(key) != null) {
          throw const NativeFailure('invalid_key', '请输入有效的单行测试密钥。');
        }
        _imageKey = key.trim();
        return {'configured': true};
      case 'images.removeKey':
        _imageKey = null;
        return {'configured': false};
      case 'system.chooseImage':
        await Future<void>.delayed(const Duration(seconds: 10));
        return {
          'markdown': '![本地模拟图片](https://fixture.seekdesk.invalid/image.png)',
        };
      case 'images.load':
        return {
          'width': 1,
          'height': 1,
          'bytes': base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
        };
      case 'images.release':
        return {'released': true};
      case 'stickers.list':
        return {'packs': []};
      default:
        throw const NativeFailure('fixture_only', '这个本机夹具没有连接外部服务。');
    }
  }
}
