import 'dart:collection';

/// Plain, session-local form state. Rates and calculation responses are always
/// refreshed; no transport, widget, controller or account credential is kept.
class ValueToolDraft {
  String amount = '', expires = '', asking = '', manualRate = '';
  String? asOf;
  String base = 'USD', quote = 'CNY';
  int cycle = 1, mode = 0;
}

class ValueToolStore {
  Object? _identity;
  final LinkedHashMap<String, ValueToolDraft> _drafts = LinkedHashMap();

  void activate(int revision, int owner, bool signedIn) {
    final identity = (revision, owner, signedIn);
    if (_identity == identity) return;
    clear();
    _identity = identity;
  }

  ValueToolDraft forTopic(String topic) {
    final draft = _drafts.remove(topic) ?? ValueToolDraft();
    _drafts[topic] = draft;
    while (_drafts.length > 16) {
      _drafts.remove(_drafts.keys.first);
    }
    return draft;
  }

  void clear() {
    _drafts.clear();
    _identity = null;
  }
}
