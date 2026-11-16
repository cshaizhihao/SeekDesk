import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../core/frame_diagnostics.dart';

/// Times synchronous rebuilding and child reconciliation below this element.
///
/// Includes initial child mounting and updates reached by updateChild. Work
/// independently scheduled on descendants, deferred LayoutBuilder callbacks,
/// layout, paint and raster work are outside this scope. Nested observations
/// overlap and must not be summed. Normal builds retain the identical child.
Widget sampleEditorBuild({required UiWorkKind kind, required Widget child}) {
  if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
    return _EditorBuildSample(kind: kind, child: child);
  }
  return child;
}

class _EditorBuildSample extends StatelessWidget {
  const _EditorBuildSample({required this.kind, required this.child});

  final UiWorkKind kind;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;

  @override
  StatelessElement createElement() => _EditorBuildSampleElement(this);
}

class _EditorBuildSampleElement extends StatelessElement {
  _EditorBuildSampleElement(_EditorBuildSample super.widget);

  @override
  void performRebuild() {
    final kind = (widget as _EditorBuildSample).kind;
    final started = DateTime.now().toUtc().microsecondsSinceEpoch;
    final frameNumber = ui.PlatformDispatcher.instance.frameData.frameNumber;
    final timer = Stopwatch()..start();
    try {
      super.performRebuild();
    } finally {
      timer.stop();
      FrameDiagnostics.recordUiWork(
        kind,
        startedUnixMicros: started,
        durationMicros: timer.elapsedMicroseconds,
        count: 1,
        frameNumber: frameNumber,
      );
    }
  }
}

/// Returns the identical child unless raw diagnostics are compiled in.
///
/// Layout measures work executed inside this scope's child.layout call. Build
/// and mounting completed before that call are excluded; a descendant
/// LayoutBuilder that mounts during the call would be included. Control rows
/// now use LimitedBox, so their ordinary build/mount cost is outside this local
/// layout timer even when an ancestor builds them during its own layout. Compare
/// full-frame framework time when work moves between build and layout phases.
/// Scopes are inclusive: a formats scope can contain a media scope, and their
/// durations must not be added together. Paint measures only work actually
/// executed, not cached layers or later raster-thread work.
Widget sampleEditorHeader({
  required UiWorkKind layoutKind,
  required UiWorkKind paintKind,
  UiWorkKind? buildKind,
  required Widget child,
}) {
  if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
    final measured = _EditorHeaderSample(
      layoutKind: layoutKind,
      paintKind: paintKind,
      child: child,
    );
    return buildKind == null
        ? measured
        : sampleEditorBuild(kind: buildKind, child: measured);
  }
  return child;
}

class _EditorHeaderSample extends SingleChildRenderObjectWidget {
  const _EditorHeaderSample({
    required this.layoutKind,
    required this.paintKind,
    required super.child,
  });

  final UiWorkKind layoutKind, paintKind;

  @override
  _RenderEditorHeaderSample createRenderObject(BuildContext context) =>
      _RenderEditorHeaderSample(layoutKind, paintKind);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderEditorHeaderSample renderObject,
  ) {
    renderObject
      ..layoutKind = layoutKind
      ..paintKind = paintKind;
  }
}

class _RenderEditorHeaderSample extends RenderProxyBox {
  _RenderEditorHeaderSample(this.layoutKind, this.paintKind);

  UiWorkKind layoutKind, paintKind;

  @override
  void performLayout() {
    if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
      final started = DateTime.now().toUtc().microsecondsSinceEpoch;
      final frameNumber = ui.PlatformDispatcher.instance.frameData.frameNumber;
      final timer = Stopwatch()..start();
      var completed = false;
      try {
        super.performLayout();
        completed = true;
      } finally {
        timer.stop();
        // A failed layout can leave no size, or only an old layout's size.
        // Preserve the original exception without reading either as a result.
        final measured = completed && hasSize ? size : null;
        FrameDiagnostics.recordUiWork(
          layoutKind,
          startedUnixMicros: started,
          durationMicros: timer.elapsedMicroseconds,
          width: measured?.width,
          height: measured?.height,
          count: 1,
          frameNumber: frameNumber,
        );
      }
    } else {
      super.performLayout();
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
      final started = DateTime.now().toUtc().microsecondsSinceEpoch;
      final frameNumber = ui.PlatformDispatcher.instance.frameData.frameNumber;
      final timer = Stopwatch()..start();
      try {
        super.paint(context, offset);
      } finally {
        timer.stop();
        final measured = hasSize ? size : null;
        FrameDiagnostics.recordUiWork(
          paintKind,
          startedUnixMicros: started,
          durationMicros: timer.elapsedMicroseconds,
          width: measured?.width,
          height: measured?.height,
          count: 1,
          frameNumber: frameNumber,
        );
      }
    } else {
      super.paint(context, offset);
    }
  }
}
