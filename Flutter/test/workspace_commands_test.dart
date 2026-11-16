import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/state/workspace_commands.dart';

WorkspaceCommandContext _context({
  bool routeCurrent = true,
  bool officeCovered = false,
  bool editing = false,
  bool forum = true,
  bool reading = true,
  bool hasSelectedTopic = true,
  bool hasClosedTopics = true,
  bool tabsBusy = false,
  bool listingLoading = false,
  bool readerLoading = false,
  bool officeEnabled = true,
  int tabCount = 3,
  bool hasBrowserTarget = true,
}) => WorkspaceCommandContext(
  routeCurrent: routeCurrent,
  officeCovered: officeCovered,
  editing: editing,
  forum: forum,
  reading: reading,
  hasSelectedTopic: hasSelectedTopic,
  hasClosedTopics: hasClosedTopics,
  tabsBusy: tabsBusy,
  listingLoading: listingLoading,
  readerLoading: readerLoading,
  officeEnabled: officeEnabled,
  tabCount: tabCount,
  hasBrowserTarget: hasBrowserTarget,
);

const _global = <WorkspaceCommand>{
  WorkspaceCommand.home,
  WorkspaceCommand.search,
  WorkspaceCommand.toggleSidebar,
  WorkspaceCommand.notifications,
  WorkspaceCommand.account,
  WorkspaceCommand.settings,
  WorkspaceCommand.extensions,
};

const _reading = <WorkspaceCommand>{
  ..._global,
  WorkspaceCommand.office,
  WorkspaceCommand.overview,
  WorkspaceCommand.refresh,
  WorkspaceCommand.openInBrowser,
  WorkspaceCommand.closeTab,
  WorkspaceCommand.reopenTab,
  WorkspaceCommand.nextTab,
  WorkspaceCommand.previousTab,
  WorkspaceCommand.toggleList,
};

const _overview = <WorkspaceCommand>{
  ..._global,
  WorkspaceCommand.office,
  WorkspaceCommand.resumeReading,
  WorkspaceCommand.refresh,
  WorkspaceCommand.openInBrowser,
  WorkspaceCommand.closeTab,
  WorkspaceCommand.reopenTab,
  WorkspaceCommand.nextTab,
  WorkspaceCommand.previousTab,
};

void _expectCommands(
  WorkspaceCommandContext context,
  Set<WorkspaceCommand> allowed,
) {
  for (final command in WorkspaceCommand.values) {
    expect(
      WorkspaceCommandPolicy.canPerform(command, context),
      allowed.contains(command),
      reason: command.name,
    );
  }
}

void main() {
  final scenarios = <(String, WorkspaceCommandContext, Set<WorkspaceCommand>)>[
    ('reading with several tabs', _context(), _reading),
    ('overview with a retained reading tab', _context(reading: false), _overview),
    (
      'settings or another root destination with background reading tabs',
      _context(forum: false),
      {..._global, WorkspaceCommand.office, WorkspaceCommand.returnToForum},
    ),
    (
      'empty overview with no browser target or closed tabs',
      _context(
        reading: false,
        hasSelectedTopic: false,
        hasClosedTopics: false,
        tabCount: 0,
        hasBrowserTarget: false,
      ),
      {..._global, WorkspaceCommand.office, WorkspaceCommand.refresh},
    ),
    (
      'editing a field while reading',
      _context(editing: true),
      {
        ..._global,
        WorkspaceCommand.office,
        WorkspaceCommand.overview,
        WorkspaceCommand.toggleList,
      },
    ),
    (
      'editing search in the overview with a retained tab',
      _context(editing: true, reading: false),
      {..._global, WorkspaceCommand.office, WorkspaceCommand.resumeReading},
    ),
    (
      'editing a field on an auxiliary root destination',
      _context(editing: true, forum: false),
      {..._global, WorkspaceCommand.office, WorkspaceCommand.returnToForum},
    ),
    (
      'reader and tabs busy',
      _context(tabsBusy: true, readerLoading: true),
      {
        ..._global,
        WorkspaceCommand.office,
        WorkspaceCommand.overview,
        WorkspaceCommand.openInBrowser,
        WorkspaceCommand.toggleList,
      },
    ),
    (
      'listing and tabs busy in overview',
      _context(reading: false, tabsBusy: true, listingLoading: true),
      {..._global, WorkspaceCommand.office, WorkspaceCommand.openInBrowser},
    ),
  ];

  group('workspace command matrix', () {
    for (final scenario in scenarios) {
      test(scenario.$1, () => _expectCommands(scenario.$2, scenario.$3));
    }
  });

  group('covering routes and office cover reject every workspace command', () {
    for (final routeCurrent in [false, true]) {
      for (final officeCovered in [false, true]) {
        if (routeCurrent && !officeCovered) continue;
        test('routeCurrent=$routeCurrent officeCovered=$officeCovered', () {
          for (final forum in [false, true]) {
            for (final reading in [false, true]) {
              for (final editing in [false, true]) {
                _expectCommands(
                  _context(
                    routeCurrent: routeCurrent,
                    officeCovered: officeCovered,
                    forum: forum,
                    reading: reading,
                    editing: editing,
                  ),
                  <WorkspaceCommand>{},
                );
              }
            }
          }
        });
      }
    }
  });

  test('office availability changes only the office command', () {
    _expectCommands(
      _context(officeEnabled: false),
      _reading.difference({WorkspaceCommand.office}),
    );
  });

  test('text editing keeps explicit navigation and blocks context shortcuts', () {
    const blocked = {
      WorkspaceCommand.refresh,
      WorkspaceCommand.openInBrowser,
      WorkspaceCommand.closeTab,
      WorkspaceCommand.reopenTab,
      WorkspaceCommand.nextTab,
      WorkspaceCommand.previousTab,
    };
    _expectCommands(_context(editing: true), _reading.difference(blocked));
    expect(
      WorkspaceCommandPolicy.canPerform(
        WorkspaceCommand.search,
        _context(editing: true),
      ),
      isTrue,
      reason: 'Explicit search can move focus from another editable control.',
    );
  });

  test('returning to the forum does not depend on whether a reader was open', () {
    for (final reading in [false, true]) {
      for (final selected in [false, true]) {
        expect(
          WorkspaceCommandPolicy.canPerform(
            WorkspaceCommand.returnToForum,
            _context(forum: false, reading: reading, hasSelectedTopic: selected),
          ),
          isTrue,
        );
        expect(
          WorkspaceCommandPolicy.canPerform(
            WorkspaceCommand.returnToForum,
            _context(reading: reading, hasSelectedTopic: selected),
          ),
          isFalse,
        );
      }
    }
  });

  test('only the current forum surface determines refresh loading state', () {
    for (final reading in [false, true]) {
      for (final listingLoading in [false, true]) {
        for (final readerLoading in [false, true]) {
          final context = _context(
            reading: reading,
            listingLoading: listingLoading,
            readerLoading: readerLoading,
          );
          expect(
            WorkspaceCommandPolicy.canPerform(WorkspaceCommand.refresh, context),
            reading ? !readerLoading : !listingLoading,
            reason:
                'reading=$reading listingLoading=$listingLoading readerLoading=$readerLoading',
          );
        }
      }
    }
  });

  test('busy tabs block close restore traversal and reading recovery', () {
    const tabCommands = {
      WorkspaceCommand.closeTab,
      WorkspaceCommand.reopenTab,
      WorkspaceCommand.nextTab,
      WorkspaceCommand.previousTab,
      WorkspaceCommand.resumeReading,
    };
    _expectCommands(_context(tabsBusy: true), _reading.difference(tabCommands));
    _expectCommands(
      _context(reading: false, tabsBusy: true),
      _overview.difference(tabCommands),
    );
  });

  test('no selected tab prevents close and resume without preventing reopen', () {
    _expectCommands(
      _context(reading: false, hasSelectedTopic: false),
      _overview.difference({
        WorkspaceCommand.closeTab,
        WorkspaceCommand.resumeReading,
      }),
    );
    _expectCommands(
      _context(reading: false, hasSelectedTopic: false, tabCount: 0),
      _overview.difference({
        WorkspaceCommand.closeTab,
        WorkspaceCommand.resumeReading,
        WorkspaceCommand.nextTab,
        WorkspaceCommand.previousTab,
      }),
    );
  });

  test('no closed history prevents reopening even with an active reading tab', () {
    _expectCommands(
      _context(hasClosedTopics: false),
      _reading.difference({WorkspaceCommand.reopenTab}),
    );
  });

  test('tab traversal requires at least two tabs in either forum surface', () {
    for (final reading in [false, true]) {
      for (final count in [-1, 0, 1, 2, 12]) {
        for (final command in [WorkspaceCommand.nextTab, WorkspaceCommand.previousTab]) {
          expect(
            WorkspaceCommandPolicy.canPerform(
              command,
              _context(reading: reading, tabCount: count),
            ),
            count >= 2,
            reason: '${command.name} reading=$reading tabs=$count',
          );
        }
      }
    }
  });

  test('browser target availability does not disable other commands', () {
    _expectCommands(
      _context(hasBrowserTarget: false),
      _reading.difference({WorkspaceCommand.openInBrowser}),
    );
    _expectCommands(
      _context(reading: false, hasBrowserTarget: false),
      _overview.difference({WorkspaceCommand.openInBrowser}),
    );
  });

  test('overview and list visibility are reading-only without tab busy coupling', () {
    for (final command in [WorkspaceCommand.overview, WorkspaceCommand.toggleList]) {
      expect(
        WorkspaceCommandPolicy.canPerform(
          command,
          _context(editing: true, tabsBusy: true, readerLoading: true),
        ),
        isTrue,
      );
      expect(
        WorkspaceCommandPolicy.canPerform(command, _context(reading: false)),
        isFalse,
      );
      expect(
        WorkspaceCommandPolicy.canPerform(command, _context(forum: false)),
        isFalse,
      );
    }
  });
}
