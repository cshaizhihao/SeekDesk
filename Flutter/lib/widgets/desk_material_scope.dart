// Keep the SDK Cupertino API used by the pinned glass package.
// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' show Theme, ThemeData;

/// Caches the SDK's ambient Material theme for a small Cupertino subtree.
///
/// Place immediately above a group such as MarkdownToolbar, whose tooltips
/// otherwise each construct CupertinoBasedMaterialThemeData in Theme.of.
/// This is deliberately local: it neither chooses a new palette/platform nor
/// installs a global Material theme or an AnimatedTheme.
class DeskMaterialScope extends StatefulWidget {
  const DeskMaterialScope({required this.child, super.key});

  final Widget child;

  @override
  State<DeskMaterialScope> createState() => _DeskMaterialScopeState();
}

class _DeskMaterialScopeState extends State<DeskMaterialScope> {
  late ThemeData _materialTheme;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Theme.of establishes the SDK's actual Material, Cupertino and
    // MaterialLocalizations dependencies. Use its exact fallback and localized
    // text geometry instead of detecting a private inherited Material theme or
    // reimplementing CupertinoBasedMaterialThemeData's defaults. Parent-only
    // updates (for example an enabled flag) do not recompute this value.
    _materialTheme = Theme.of(context);
  }

  @override
  Widget build(BuildContext context) =>
      _PreserveWidgetThemes(materialTheme: _materialTheme, child: widget.child);
}

/// This element is above the new Theme. Its style dependencies are separate
/// from the expensive cache: an IconTheme/selection-only update rebuilds this
/// adapter without rerunning the parent's Theme.of fallback conversion.
class _PreserveWidgetThemes extends StatelessWidget {
  const _PreserveWidgetThemes({
    required this.materialTheme,
    required this.child,
  });

  final ThemeData materialTheme;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cupertino = context
        .dependOnInheritedWidgetOfExactType<InheritedCupertinoTheme>()
        ?.theme
        .data;
    final icons = context.dependOnInheritedWidgetOfExactType<IconTheme>()?.data;
    final selection = DefaultSelectionStyle.of(context);

    return Theme(
      data: materialTheme,
      // Theme.build inserts its own CupertinoTheme, IconTheme and selection
      // style. Restore their original raw values below those wrappers so
      // dynamic colors, nullable icon overrides and mouseCursor still behave
      // as they did outside this scope. InheritedCupertinoTheme is public and
      // avoids another CupertinoTheme.build inserting an unwanted IconTheme.
      child: InheritedCupertinoTheme(
        theme: CupertinoTheme(
          data: cupertino ?? const CupertinoThemeData(),
          child: const SizedBox.shrink(),
        ),
        child: IconTheme(
          data: icons ?? const IconThemeData.fallback(),
          child: DefaultSelectionStyle(
            cursorColor: selection.cursorColor,
            selectionColor: selection.selectionColor,
            mouseCursor: selection.mouseCursor,
            // Theme adds no DefaultTextStyle. Leaving it untouched preserves
            // every field, including wrapping, width and height behavior, as
            // well as all other ambient inherited styles and accessibility.
            child: child,
          ),
        ),
      ),
    );
  }
}
