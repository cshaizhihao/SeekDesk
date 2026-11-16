import 'dart:async';

import 'package:flutter/services.dart';
import 'package:seekdesk_flutter/core/native_client.dart';

JsonMap rankingPost(int position, {String? id, String? title}) => {
  'id': id ?? '$position',
  'url': 'https://www.nodeseek.com/post-${id ?? position}-1',
  'position': position,
  'title': title ?? 'Fixture ranking $position',
  'author': 'Author $position',
  'authorID': 1000 + position,
  'normalizedAuthor': 'author $position',
  'replies': 3,
  'views': 100,
};

class RankingRequest {
  RankingRequest(this.arguments);
  final JsonMap arguments;
  final result = Completer<JsonMap>();

  void complete({List<JsonMap>? posts, String? error, int? updatedAt}) {
    result.complete({
      'period': arguments['period'],
      'posts': posts ?? [rankingPost(1)],
      'updatedAt': updatedAt ?? 1700000000,
      'error': ?error,
    });
  }
}

/// Local-only fixture: never reaches channels, accounts, or the forum.
class RankingsNative extends NativeClient {
  RankingsNative()
    : super(methods: MethodChannel('seekdesk.test.rankings.${_nextChannel++}'));

  static int _nextChannel = 0;
  final snapshotEvents = StreamController<JsonMap>.broadcast(sync: true);
  final calls = <(String, JsonMap)>[];
  final requests = <RankingRequest>[];
  JsonMap extensions = {
    'items': [
      {'id': 'hot', 'active': true},
      {'id': 'block', 'active': false},
    ],
    'blocked': <JsonMap>[],
  };
  JsonMap settings = {'workspace.rankingTextSize': 12};

  @override
  Stream<JsonMap> get snapshots => snapshotEvents.stream;

  @override
  Future<JsonMap> call(String method, [JsonMap arguments = const {}]) {
    final captured = {...arguments, 'accessRevision': accessRevision};
    calls.add((method, captured));
    switch (method) {
      case 'bootstrap':
        return Future.value({
          'session': {'account': 'signedIn', 'owner': 100, 'accessRevision': 0},
          'workspace': {
            'posts': <JsonMap>[],
            'tabs': <JsonMap>[],
            'showReader': false,
          },
          'settings': settings,
          'extensions': extensions,
        });
      case 'rankings.load':
        final request = RankingRequest(captured);
        requests.add(request);
        return request.result.future;
      case 'reader.open':
        return Future.value({
          'tabs': [
            {
              'id': 'fixture',
              'url': arguments['url'],
              'title': 'Ranking fixture',
            },
          ],
          'selectedTab': 'fixture',
          'showReader': true,
        });
      case 'reader.load':
        return Future.value({
          'url': arguments['url'],
          'thread': {
            'title': 'Ranking fixture',
            'root': {'id': '0', 'author': 'Fixture', 'blocks': <JsonMap>[]},
            'replies': <JsonMap>[],
          },
        });
      default:
        throw StateError('Unexpected fixture operation: $method');
    }
  }

  void emit(String domain, JsonMap data, {int? revision}) =>
      snapshotEvents.add({
        'domain': domain,
        'data': data,
        'accessRevision': revision ?? accessRevision,
      });

  void account(int revision) => emit('session', {
    'account': 'signedIn',
    'owner': 100 + revision,
    'accessRevision': revision,
  }, revision: revision);

  void completePending() {
    for (final request in requests) {
      if (!request.result.isCompleted) request.complete(posts: []);
    }
  }
}
