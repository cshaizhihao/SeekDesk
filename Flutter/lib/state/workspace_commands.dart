enum WorkspaceCommand {
  home,
  search,
  toggleSidebar,
  office,
  notifications,
  account,
  settings,
  extensions,
  returnToForum,
  overview,
  resumeReading,
  refresh,
  openInBrowser,
  closeTab,
  reopenTab,
  nextTab,
  previousTab,
  toggleList,
}

/// An immutable snapshot of the workspace's command capabilities.
///
/// [editing] means an editable control owns the focus. A covering editor,
/// dialog, or image route instead makes [routeCurrent] false.
class WorkspaceCommandContext {
  const WorkspaceCommandContext({
    required this.routeCurrent,
    required this.officeCovered,
    required this.editing,
    required this.forum,
    required this.reading,
    required this.hasSelectedTopic,
    required this.hasClosedTopics,
    required this.tabsBusy,
    required this.listingLoading,
    required this.readerLoading,
    required this.officeEnabled,
    required this.tabCount,
    required this.hasBrowserTarget,
  });

  final bool routeCurrent;
  final bool officeCovered;
  final bool editing;
  final bool forum;
  final bool reading;
  final bool hasSelectedTopic;
  final bool hasClosedTopics;
  final bool tabsBusy;
  final bool listingLoading;
  final bool readerLoading;
  final bool officeEnabled;
  final int tabCount;
  final bool hasBrowserTarget;
}

/// Pure capability checks shared by workspace buttons and keyboard commands.
///
/// Callers obtain a fresh context before executing an action. This policy owns
/// no routes, account state, or side effects. The global office shortcut that
/// can cover another route or dismiss its cover remains a separate action.
abstract final class WorkspaceCommandPolicy {
  static bool canPerform(
    WorkspaceCommand command,
    WorkspaceCommandContext context,
  ) {
    if (!context.routeCurrent || context.officeCovered) return false;

    return switch (command) {
      WorkspaceCommand.home ||
      WorkspaceCommand.search ||
      WorkspaceCommand.toggleSidebar ||
      WorkspaceCommand.notifications ||
      WorkspaceCommand.account ||
      WorkspaceCommand.settings ||
      WorkspaceCommand.extensions => true,
      WorkspaceCommand.office => context.officeEnabled,
      WorkspaceCommand.returnToForum => !context.forum,
      WorkspaceCommand.overview || WorkspaceCommand.toggleList =>
        context.forum && context.reading,
      WorkspaceCommand.resumeReading =>
        context.forum &&
            !context.reading &&
            context.hasSelectedTopic &&
            !context.tabsBusy,
      WorkspaceCommand.refresh =>
        context.forum &&
            !context.editing &&
            (context.reading
                ? !context.readerLoading
                : !context.listingLoading),
      WorkspaceCommand.openInBrowser =>
        context.forum && !context.editing && context.hasBrowserTarget,
      WorkspaceCommand.closeTab =>
        context.forum &&
            !context.editing &&
            context.hasSelectedTopic &&
            !context.tabsBusy,
      WorkspaceCommand.reopenTab =>
        context.forum &&
            !context.editing &&
            context.hasClosedTopics &&
            !context.tabsBusy,
      WorkspaceCommand.nextTab || WorkspaceCommand.previousTab =>
        context.forum &&
            !context.editing &&
            context.tabCount > 1 &&
            !context.tabsBusy,
    };
  }
}
