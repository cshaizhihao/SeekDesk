# SeekDesk native channel v1

Methods: `cc.seekdesk/native.methods.v1`. Events: `cc.seekdesk/native.events.v1`.
Every client call injects `accessRevision`; native writes reject stale revisions.
Methods return a domain snapshot or a bootstrap-shaped map. Failures use
`FlutterError(code,message,details)` and appear as interface errors.

Event: `{domain:String,data:Map,accessRevision:Int}`. Domain snapshots replace
that domain. A full snapshot uses domain `snapshot` or `bootstrap`.

Bootstrap domains:

- `workspace`: `posts`, `tabs`, `closedTabs` arrays, `selectedTab` string/null,
  `board` string, `boardURL`, `boardCategoryID`,
  `boards:[{id,title,icon,searchable}]`, `loading`, `canLoadOlder`,
  `hasForumPage`, `failedToRefresh`, `failedToLoadOlder`, nullable `error`/`errorCode`;
  `query`, `appliedSearchScope`, `appliedSearchKind`, `searchHistory`,
  `people`, `showsPeopleResults`, `peopleLoading`, nullable `peopleError`/`peopleErrorCode`.
- Post/tab: `{id,url,title,author?,authorID?,avatar?,category?,published?,summary?}`.
- `session`: `{account:'signedIn'|'signedOut'|'unconfirmed',profile?,accessRevision}`.
- `settings`, `extensions`, `proxy`: domain maps.

Bootstrap also carries top-level `version` and `build` strings from the running
bundle's `CFBundleShortVersionString` and `CFBundleVersion`; unavailable values
are empty strings, never a hardcoded release version. Flutter retains accepted
nonblank strings across partial/session snapshots and account revisions, ignores
stale snapshots and invalid metadata, and displays unavailable version information
honestly. These nonsecret process values are separate from account domains and
are not written to preferences. `updates.check` reads the latest stable GitHub
release on demand and compares it with the running bundle version. It returns
`status`, and when available `version` and `releaseURL`. A newer release must
provide an appcast for installation to be offered. `updates.install` flushes
drafts and opens the native signed updater. The About releases link uses the existing
`external.open{url}` action with `https://github.com/cshaizhihao/SeekDesk/releases`;
it opens the GitHub release history.

`reader.load{url,force?}` → `{url,loading?,error?,thread?}`. Thread/floor/block/tab/
table/terminal fields match existing Swift ForumThread values.
`reader.authorPage{url,page}` → `{thread,accessRevision}` reads a second page of
the same topic through the authenticated forum loader. It leaves the current
reader and its interaction context in place.
Flutter's reader cache accepts the correlated `reader.load` method response,
and still accepts an initial `bootstrap.reader` snapshot. Native reader events
currently contain only loading/completion/clear snapshots and no operation ID;
Flutter does not apply those uncorrelated payloads to the cache. This prevents a
queued completion event from a closed page overwriting a newly reopened request
for the same URL. Session revision events still clear all private reader state.
Flutter owns the local loading state and deduplicates requests by canonical page
URL, request identity and access revision. Successful close-all invalidates the
reader generation before a reopen can issue a new request. Cancelled or obsolete
requests never create error-cache entries, and an old completion cannot remove
the new request. Current-revision account-discovery retry responses remain valid
only while that request still owns its page.
`images.load{url}` → `{bytes:FlutterStandardTypedData,mime?,width?,height?}`.
Cookies, image networking and proxy routing stay native. Dart makes no forum HTTP calls.

Workspace: `listing.selectBoard{id}`, `listing.refresh`, `listing.older`,
`listing.search{query,scope?,kind?}`, `listing.clearSearch`, `listing.clearHistory`,
`reader.open{url,background?:bool}` (background preserves current selection, page and scroll; no body fetch), `reader.select{id}`,
`reader.close{id}`, `reader.closeAll`, `reader.reopen{id?}`, `reader.move{id,to}`.
Move places `id` at the target tab's original array index and keeps the selected
tab unchanged. Closed history is oldest-first; the UI presents it newest-first.
Reopen without `id` restores the newest entry; an explicit topic `id` restores
that entry at its saved position and selects it. Close-all preserves closed
history and account-scoped drafts; Flutter flushes pending local drafts before
requesting the operation. These are local workspace operations, not forum writes.

Listing errors use fixed codes: `verification`, `signInRequired`, `missing`,
`changed`, `timedOut`, `network`, `rateLimited`. Error strings contain only
predefined context-appropriate text, never raw request or transport details.
Post errors and people errors are independent: a failed directory request must
not appear as a successful empty result, nor hide available post results.
`errorCode` prefers the refresh failure over a pagination failure if both exist;
use the two failure booleans to choose `listing.refresh` versus `listing.older`.
Retained results remain visible with their failure state. Automatic pagination
is disabled during search and after a pagination failure; explicit retry remains
available. `hasForumPage` refers to the current board's HTML listing cache,
not the current search result; false with visible board posts indicates the
RSS fallback. Clearing search preserves cached boards, tabs and history and
reads the board only when its HTML listing cache is absent.

Session/external: `session.signIn`, `session.verify{url}`, `external.open{url}`.
Settings: `settings.get`, `settings.update{key,value}`, `settings.openNotifications`.
Inbox: `inbox.load{kind}`.
Discussion: `discussion.getDraft`, `discussion.updateDraft{title,content,category,rank}`,
`discussion.loadOptions` → `{categories:[{id,title}],maxRank}`,
`discussion.publish{feeAccepted}`, `discussion.discard`.
Reader writes: `reader.replyDraft{topicID}`, `reader.updateReplyDraft{topicID,content}`,
`reader.sendReply{topicID,url}`, `reader.react{topicID,floor,kind}`.

Absent domains show loading, errors, or an empty state; no demo fallback exists.

## Settings, extensions and proxy (native implementation)

`settings.get` → flat map keyed by existing native defaults names. `settings.update{key,value}`
accepts only UI preference keys; enums and numeric ranges are checked natively. Defaults:
appearance=system, workspace.logoPalette=Cobalt, workspace.replySendKey=commandReturn,
workspace.readingDensity=comfortable, workspace.listTextSize=15,
workspace.readerTextSize=15, workspace.floorAuthorScale=100,
workspace.boardTextSize=13, workspace.rankingTextSize=12,
workspace.nqReportScale=100, workspace.tqReportScale=100,
workspace.sidebarWidth=228, workspace.topicColumnWidth=340,
workspace.mistBackdrop=true, workspace.autoLoadOlder=false,
workspace.autoRefresh=true, workspace.hideListWhileReading=false.

`settings.openNotifications` accepts no business arguments; it allows the standard
optional `accessRevision` transport metadata (a nonnegative integer, never a boolean).
It opens only
`x-apple.systempreferences:com.apple.Notifications-Settings.extension` via the
native workspace. It returns `{opened:true}` on success, `unavailable` if macOS
cannot open the settings pane, and `invalid_arguments` for any business arguments
or malformed transport metadata.

`extensions.list` → `{items:[{id,title,description,icon,installed,enabled,active}],
installed:[id],enabled:[id],blocked:[{id,memberId,name}],settings:{
office:{title,button,key,presented},keywords:{words,note,systemNotifications,
notificationAccess,terms},attendance:{mode,automatic}},hits:[{id,words,post}],
unread,lastCheck,watchFailed,watchPopup:null|{id,hits}}`.
IDs: hot/attendance/office/value/block/authorOnly/keywords/rulings/proxy.
Calls: `extensions.install{id}`, `extensions.uninstall{id}`,
`extensions.setEnabled{id,enabled}`, `extensions.configure{id,settings:{...}}`,
`extensions.block{memberId?,name}`, `extensions.unblock{memberId?,name?}`,
`extensions.acknowledgeHits`, `extensions.dismissWatchPopup`,
`extensions.office{presented}`. Configure accepts office title/button/key,
keywords words/note/systemNotifications, attendance mode(fixed|random)/automatic,
or proxy startWithApp. Automatic attendance execution is a separate native service.

`proxy.get` → `{available,nodes:[{id,name,scheme,protocolName,host,port,
subscriptionId,latency:{state:'idle'|'measuring'|'success'|'failed',milliseconds?}}],
subscriptions:[{id,name,updatedAt,updating,nodeCount}],selectedId,enabled,running,
starting,checking,status,issue,checkResult,importMessage,startWithApp,
canMeasureMoreNodes,supportedProtocols}`.
No raw node link, outbound configuration, subscription URL or keychain values
appear in these domain snapshots/events.

- `proxy.import{text,name?,preview?}` accepts a node URL, newline/Base64 list,
  or Clash YAML/JSON. `preview:true` returns
  `{importToken,summary,nodes,skipped,duplicates,subscription:false}`.
- `proxy.subscribe{url,name?,preview?}` fetches and parses a subscription through
  the native app route; same preview response with `subscription:true`.
- Commit preview with `proxy.import{importToken,name?}` (works for both kinds).
  Omit preview or set false to import directly. Preview holds native credentials
  for at most10minutes, maximum4previews. `proxy.discardImport{importToken}` releases it.
- `proxy.editNode{id}` is a dedicated explicit edit request returning `{id,name,link}`;
  `proxy.import{text,name?,replacingId}` saves its changes through production validation.
- `proxy.select{id}`, `proxy.start`, `proxy.stop`, `proxy.reconnect`, `proxy.check`,
  `proxy.remove{id}`, `proxy.updateSubscription{id}`, `proxy.removeSubscription{id}`,
  `proxy.configure{startWithApp}`, `proxy.probe{id}`, `proxy.cancelProbes` return snapshot.
  `proxy.probe` immediately starts full-protocol latency measurement and events
  deliver measuring→success/failed. Keep UI button lightning-only. At most4concurrent.

Proxy and extensions publish domain snapshot events after asynchronous updates;
widgets should render state returned by native instead of guessing connection success.

## Reader lifecycle and positions

`reader.rememberPosition{url,offset?,anchor?}` returns `{saved,scrollOffset}`.
Offset must be finite and between0and100000000. Anchor is optional; when provided
it must be a string `thread-title`, `thread-discussion`, or `floor-<digits>`.
Do not send an anchor object. `reader.load` snapshots include `scrollOffset`
(default0) plus optional stable `anchor`. The native store keeps at most500pages
per account/guest partition, uses canonical topic-page URLs and debounces writes.
Scroll UI should debounce sends and avoid writing after its account revision changes.

Read operations `reader.load`, `inbox.load`, `profile.load`, `discussion.loadOptions`
may discover the actual cookie identity. Native clears old private state and repeats
the read under the new revision (at most3attempts); returned maps identify the current
revision. A client may accept these current-revision read results after an identity
event; writes still require the revision captured by the originating editor.
Inbox readers are independent by category/peer; late older selections cancel instead
of overwriting the selected category. Unread counts continuously advance independent
category revisions, including fall-then-rise between view loads.

`stickers.list` returns `{packs:[...]}` and `rulings.load{name}` returns
`{records:[...]}`. All list payloads live inside maps for NativeClient compatibility.

## Lifecycle, navigation and remaining migrated services

Host callback `lifecycle.flush` returns `{saved:Bool}` only after registered local
composer/message saves and outstanding save futures settle. Dirty server-side
profile/post editors return false; no server writes occur as part of quitting.
macOS window close and application termination wait for this callback, with an
8-second timeout that preserves the window on failure.

Native events may include `navigation:{destination:'forum'|'inbox'|'extensions'|'settings',id}`.
The workspace handles this without forcibly dismissing dirty editor routes.
`shortcuts.list` returns `{items:[{id,title,icon,url}]}`; the same map is in bootstrap.
`shortcuts.open{id}` opens the existing native authenticated official NodeSeek page.
These WebKit pages retain the app's session and app-only proxy route.

`reader.edit.save` returns `accepted:true` only when native save confirmed success.
Reader thread DTOs recursively populate ANSI terminal spans using the native parser.
`reader.rememberPosition{url,offset,anchor?}` stores finite offsets per account and
page, bounded to 500 entries per partition; native stable anchors remain supported.

`value.currencies` returns `{items:[{code,title}]}`.
`value.rate{base,quote,force?}` returns `{rate:String,source,caption?,asOf,base,quote}`.
`value.hint{title}` returns `{available,amount?,base?,cycle?}`.
`value.calculate{amount:String,cycle:Int,expires:milliseconds,rate?:String,quote?,asking?:String}`
returns remaining time/amount and optional `converted,formatted,difference,
differenceLabel,differenceAmount`. Conversion and comparisons use native Decimal;
rate failure does not fabricate a fallback exchange rate.

`space.activity{memberId,route:'discussions'|'comments',page}` and
`space.members{memberId,route:'fans'|'follow'}` return
`{route,memberId,page,items,hasNext,accessRevision}`. Private member lists require the
current owner and all responses reject account changes while in flight. Directory
networking uses the context's native WebKit data store and proxy.
