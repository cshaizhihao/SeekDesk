import 'dart:math' as math;

// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';

import '../core/frame_diagnostics.dart';

/// The reader owns this panel's viewport height. Tools use their natural height;
/// only panes too short for the tools and minimum editor scroll as a whole.
class ReaderMarkdownWorkspace extends StatelessWidget {
  const ReaderMarkdownWorkspace({
    required this.heading,
    required this.header,
    required this.editor,
    required this.footer,
    this.minimumEditorHeight = 110,
    super.key,
  });

  final Widget heading, editor, footer;
  final List<Widget> header;
  final double minimumEditorHeight;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final width = bounds.hasBoundedWidth ? bounds.maxWidth : 700.0;
      final viewportHeight = bounds.hasBoundedHeight ? bounds.maxHeight : 340.0;
      // Keep one tree through wrapping, resizing, and changes to header notices.
      // The editor gets a bounded viewport without intrinsic measurement or
      // moving its element between a scrolling and non-scrolling parent.
      return SingleChildScrollView(
        key: const ValueKey('reader-markdown-panel-scroll'),
        primary: false,
        child: SizedBox(
          width: width,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: _ReaderMarkdownLayout(
              minimumHeight: math.max(0.0, viewportHeight - 20),
              minimumEditorHeight: minimumEditorHeight,
              children: [
                heading,
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: header,
                ),
                SizedBox(
                  key: const ValueKey('markdown-workspace-editor'),
                  child: editor,
                ),
                footer,
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// Preserve the available column width so control groups can wrap naturally.
class ReaderMarkdownControlRow extends StatelessWidget {
  const ReaderMarkdownControlRow({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => LimitedBox(
    maxWidth: 700,
    child: SizedBox(width: double.infinity, child: child),
  );
}

/// Measure the three auxiliary areas first, then give the editor the remaining
/// height. This avoids guessed toolbar row counts and intrinsic queries into
/// EditableText. The surrounding scroll view supplies unbounded vertical space
/// when all four areas cannot fit in the reader's viewport.
class _ReaderMarkdownLayout extends MultiChildRenderObjectWidget {
  const _ReaderMarkdownLayout({
    required this.minimumHeight,
    required this.minimumEditorHeight,
    required super.children,
  });

  final double minimumHeight, minimumEditorHeight;

  @override
  _RenderReaderMarkdownLayout createRenderObject(BuildContext context) =>
      _RenderReaderMarkdownLayout(minimumHeight, minimumEditorHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderReaderMarkdownLayout renderObject,
  ) {
    renderObject
      ..minimumHeight = minimumHeight
      ..minimumEditorHeight = minimumEditorHeight;
  }
}

class _ReaderMarkdownParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderReaderMarkdownLayout extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _ReaderMarkdownParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _ReaderMarkdownParentData> {
  _RenderReaderMarkdownLayout(this._minimumHeight, this._minimumEditorHeight);

  double _minimumHeight, _minimumEditorHeight;

  set minimumHeight(double value) {
    if (_minimumHeight == value) return;
    _minimumHeight = value;
    markNeedsLayout();
  }

  set minimumEditorHeight(double value) {
    if (_minimumEditorHeight == value) return;
    _minimumEditorHeight = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ReaderMarkdownParentData) {
      child.parentData = _ReaderMarkdownParentData();
    }
  }

  @override
  void performLayout() {
    assert(childCount == 4);
    assert(constraints.hasBoundedWidth);
    Stopwatch? layoutTimer;
    int? layoutStarted;
    if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
      layoutStarted = DateTime.now().toUtc().microsecondsSinceEpoch;
      layoutTimer = Stopwatch()..start();
    }
    final width = constraints.maxWidth;
    final auxiliaryConstraints = BoxConstraints.tightFor(width: width);
    final heading = firstChild!;
    final header = childAfter(heading)!;
    final editor = childAfter(header)!;
    final footer = childAfter(editor)!;
    for (final child in [heading, header, footer]) {
      if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
        _layoutTimed(
          child,
          auxiliaryConstraints,
          identical(child, heading)
              ? UiWorkKind.editorLayoutHeading
              : identical(child, header)
              ? UiWorkKind.editorLayoutHeader
              : UiWorkKind.editorLayoutFooter,
        );
      } else {
        child.layout(auxiliaryConstraints, parentUsesSize: true);
      }
    }
    final headingGap = header.size.height > 0 ? 6.0 : 0.0;
    const editorGap = 8.0;
    final footerGap = footer.size.height > 0 ? 8.0 : 0.0;
    final auxiliaryHeight =
        heading.size.height +
        headingGap +
        header.size.height +
        editorGap +
        footerGap +
        footer.size.height;
    final editorHeight = math.max(
      _minimumEditorHeight,
      _minimumHeight - auxiliaryHeight,
    );
    final editorConstraints = BoxConstraints.tightFor(
      width: width,
      height: editorHeight,
    );
    if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
      _layoutTimed(editor, editorConstraints, UiWorkKind.editorLayoutBody);
    } else {
      editor.layout(editorConstraints, parentUsesSize: true);
    }

    void place(RenderBox child, double y) {
      (child.parentData! as _ReaderMarkdownParentData).offset = Offset(0, y);
    }

    place(heading, 0);
    final headerY = heading.size.height + headingGap;
    place(header, headerY);
    final editorY = headerY + header.size.height + editorGap;
    place(editor, editorY);
    place(footer, editorY + editor.size.height + footerGap);
    size = constraints.constrain(
      Size(width, auxiliaryHeight + editor.size.height),
    );
    if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
      final timer = layoutTimer!;
      timer.stop();
      FrameDiagnostics.recordUiWork(
        UiWorkKind.editorLayout,
        startedUnixMicros: layoutStarted,
        durationMicros: timer.elapsedMicroseconds,
        width: size.width,
        height: size.height,
        count: 1,
      );
    }
  }

  void _layoutTimed(
    RenderBox child,
    BoxConstraints childConstraints,
    UiWorkKind kind,
  ) {
    if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
      final started = DateTime.now().toUtc().microsecondsSinceEpoch;
      final timer = Stopwatch()..start();
      child.layout(childConstraints, parentUsesSize: true);
      timer.stop();
      FrameDiagnostics.recordUiWork(
        kind,
        startedUnixMicros: started,
        durationMicros: timer.elapsedMicroseconds,
        width: child.size.width,
        height: child.size.height,
        count: 1,
      );
    } else {
      child.layout(childConstraints, parentUsesSize: true);
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
