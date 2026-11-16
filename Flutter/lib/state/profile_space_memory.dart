import 'dart:collection';

import '../core/native_client.dart';
import 'activity_memory.dart';

/// In-memory continuity for a small number of visited profiles. No controllers,
/// contexts, requests or unsaved introduction drafts are retained here.
class ProfileSpaceMemory {
  String section = 'overview';
  double overviewOffset = 0;
  JsonMap profile = const {};
  JsonMap introduction = const {};
  final Map<String, ActivityPaneMemory> _activities = {};

  ActivityPaneMemory activity(String route) =>
      _activities.putIfAbsent(route, ActivityPaneMemory.new);

  void clear() {
    section = 'overview';
    overviewOffset = 0;
    profile = introduction = const {};
    for (final activity in _activities.values) {
      activity.clear();
    }
    _activities.clear();
  }
}

class ProfileSpaceStore {
  Object? _identity;
  final LinkedHashMap<int, ProfileSpaceMemory> _members = LinkedHashMap();

  void activate(int revision, int owner, bool signedIn) {
    final identity = (revision, owner, signedIn);
    if (_identity == identity) return;
    clear();
    _identity = identity;
  }

  ProfileSpaceMemory forMember(int member) {
    final memory = _members.remove(member) ?? ProfileSpaceMemory();
    _members[member] = memory;
    while (_members.length > 16) {
      // Eviction drops the store's reference. A still-mounted page may retain
      // its own memory until its lifetime ends.
      _members.remove(_members.keys.first);
    }
    return memory;
  }

  void clear() {
    for (final memory in _members.values) {
      memory.clear();
    }
    _members.clear();
    _identity = null;
  }
}
