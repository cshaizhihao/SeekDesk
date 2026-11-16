import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/frame_diagnostics.dart';
import 'package:seekdesk_flutter/widgets/editor_header_diagnostics.dart';

class _ProbeData {
  final layouts = <({BoxConstraints constraints, Size size, int frame})>[];
  final paints = <({Size size, int frame})>[];
}

class _Probe extends LeafRenderObjectWidget {
  const _Probe(this.data);
  final _ProbeData data;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderProbe(data);
}

class _RenderProbe extends RenderBox {
  _RenderProbe(this.data);
  final _ProbeData data;

  @override
  void performLayout() {
    size = constraints.constrain(const Size(120, 32));
    data.layouts.add((
      constraints: constraints,
      size: size,
      frame: ui.PlatformDispatcher.instance.frameData.frameNumber,
    ));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    data.paints.add((
      size: size,
      frame: ui.PlatformDispatcher.instance.frameData.frameNumber,
    ));
    context.canvas.drawRect(offset & size, Paint());
  }

  @override
  bool hitTestSelf(Offset position) => true;
}

Widget _surface(Widget child, {double width = 240}) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(
    child: SizedBox(width: width, height: 50, child: child),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('normal builds return the exact child without a diagnostic wrapper', () {
    const child = SizedBox(width: 120, height: 32);
    for (final kinds in [
      (UiWorkKind.editorControlsLayout, UiWorkKind.editorControlsPaint),
      (UiWorkKind.editorFormatsLayout, UiWorkKind.editorFormatsPaint),
      (UiWorkKind.editorMediaLayout, UiWorkKind.editorMediaPaint),
    ]) {
      expect(
        sampleEditorHeader(
          layoutKind: kinds.$1,
          paintKind: kinds.$2,
          child: child,
        ),
        same(child),
      );
    }
  }, skip: FrameDiagnostics.enabled && FrameDiagnostics.rawFrames);

  testWidgets('scope preserves constraints, geometry, semantics and taps', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final data = _ProbeData();
      var taps = 0;
      const key = ValueKey('measured-control');
      final child = Semantics(
        key: key,
        container: true,
        button: true,
        label: 'Measured control',
        onTap: () => taps++,
        child: GestureDetector(
          excludeFromSemantics: true,
          onTap: () => taps++,
          child: _Probe(data),
        ),
      );
      await tester.pumpWidget(_surface(child));
      final baselineRect = tester.getRect(find.byKey(key));
      final baselineConstraints = data.layouts.single.constraints;
      expect(
        tester.getSemantics(find.byKey(key)),
        matchesSemantics(
          label: 'Measured control',
          isButton: true,
          hasTapAction: true,
          textDirection: TextDirection.ltr,
        ),
      );

      await tester.pumpWidget(
        _surface(
          sampleEditorHeader(
            layoutKind: UiWorkKind.editorControlsLayout,
            paintKind: UiWorkKind.editorControlsPaint,
            child: child,
          ),
        ),
      );
      expect(tester.getRect(find.byKey(key)), baselineRect);
      expect(data.layouts.last.constraints, baselineConstraints);
      expect(
        tester.getSemantics(find.byKey(key)),
        matchesSemantics(
          label: 'Measured control',
          isButton: true,
          hasTapAction: true,
          textDirection: TextDirection.ltr,
        ),
      );
      await tester.tap(find.byKey(key));
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('raw scope records actual layout and paint with frame and size', (
    tester,
  ) async {
    final records = <Map<String, dynamic>>[];
    final data = _ProbeData();
    final child = sampleEditorHeader(
      layoutKind: UiWorkKind.editorFormatsLayout,
      paintKind: UiWorkKind.editorFormatsPaint,
      child: _Probe(data),
    );
    addTearDown(FrameDiagnostics.stop);
    await runZoned(
      () async {
        FrameDiagnostics.start();
        final started = DateTime.now().microsecondsSinceEpoch;
        await tester.pumpWidget(_surface(child));
        expect(records, hasLength(1));
        FrameDiagnostics.report();
        final first = records.last['uiWorkSamples'] as List<dynamic>;
        expect(first, hasLength(2));
        expect(data.layouts, hasLength(1));
        expect(data.paints, hasLength(1));
        for (final sample in first) {
          expect(
            sample['startedUnixMicros'],
            inInclusiveRange(started, DateTime.now().microsecondsSinceEpoch),
          );
          expect(sample['durationMicros'], greaterThanOrEqualTo(0));
          expect(sample['width'], 240);
          expect(sample['height'], 50);
          expect(sample['count'], 1);
        }
        expect(first[0]['kind'], 'editorFormatsLayout');
        expect(first[0]['frameNumber'], data.layouts.single.frame);
        expect(first[1]['kind'], 'editorFormatsPaint');
        expect(first[1]['frameNumber'], data.paints.single.frame);

        final reports = records.length;
        await tester.pump();
        FrameDiagnostics.report();
        expect(records, hasLength(reports));
        expect(data.layouts, hasLength(1));
        expect(data.paints, hasLength(1));

        await tester.pumpWidget(_surface(child, width: 260));
        FrameDiagnostics.report();
        final resized = records.last['uiWorkSamples'] as List<dynamic>;
        expect(resized, hasLength(2));
        expect(data.layouts, hasLength(2));
        expect(data.paints, hasLength(2));
        expect(resized[0]['kind'], 'editorFormatsLayout');
        expect(resized[1]['kind'], 'editorFormatsPaint');
        for (final sample in resized) {
          expect(sample['width'], 260);
          expect(sample['height'], 50);
        }
        FrameDiagnostics.stop();
      },
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) =>
            records.add(jsonDecode(line) as Map<String, dynamic>),
      ),
    );
    expect(tester.takeException(), isNull);
  }, skip: !FrameDiagnostics.enabled || !FrameDiagnostics.rawFrames);
}
