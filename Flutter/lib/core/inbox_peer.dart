/// Read a numeric UID or a canonical NodeSeek profile link. Only the resulting
/// integer reaches the native profile reader; no supplied URL is navigated.
int? parseInboxPeerID(String input) {
  final text = input.trim();
  if (text.isEmpty || text.length > 2048) return null;
  if (RegExp(r'^[0-9]+$').hasMatch(text)) return _positiveID(text);
  if (RegExp(r'[\x00-\x20\x7f]').hasMatch(text)) return null;
  final components = RegExp(
    r'^https://([^/?#]+)(/[^?#]*)?(?:[?#].*)?$',
    caseSensitive: false,
  ).firstMatch(text);
  if (components == null ||
      !RegExp(
        r'^(?:www\.)?nodeseek\.com(?::443)?$',
        caseSensitive: false,
      ).hasMatch(components[1]!)) {
    return null;
  }
  // Inspect the raw path before Uri can normalize dot segments or decode an
  // encoded separator into a different path. This must be a profile, not a
  // topic, arbitrary host, user-info authority, redirect or relative link.
  final path = RegExp(r'^/space/([0-9]+)/?$').firstMatch(components[2] ?? '');
  if (path == null) return null;
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.scheme != 'https' ||
      !const ['nodeseek.com', 'www.nodeseek.com'].contains(uri.host) ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443) {
    return null;
  }
  return _positiveID(path[1]!);
}

int? _positiveID(String value) {
  final id = int.tryParse(value);
  // Keep identifiers exact through every JSON/native/web bridge involved in
  // the existing forum services, including JavaScript's integer range.
  return id != null && id > 0 && id <= 9007199254740991 ? id : null;
}

String? inboxPeerLookupError(String input, {int? owner}) {
  if (input.trim().isEmpty) return '请输入对方的 UID 或 NodeSeek 个人主页链接。';
  final id = parseInboxPeerID(input);
  if (id == null) return '请输入有效的数字 UID 或 NodeSeek 个人主页链接。';
  if (id == owner) return '请输入对方的 UID，不能向自己发起私信。';
  return null;
}
