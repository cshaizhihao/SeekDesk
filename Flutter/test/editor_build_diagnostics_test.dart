import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/core/frame_diagnostics.dart';
import 'package:seekdesk_flutter/widgets/editor_header_diagnostics.dart';

const _buildKinds = [
  UiWorkKind.editorControlsBuild,
  UiWorkKind.editorFormatsBuild,
  UiWorkKind.editorMediaBuild,
  UiWorkKind.editorBodyBuild,
  UiWorkKind.editorHeadingBuild,
  UiWorkKind.editorFooterBuild,
  UiWorkKind.editorToolBuild,
  UiWorkKind.editorToolGlassBuild,
  UiWorkKind.editorUndoBuild,
  UiWorkKind.editorRedoBuild,
  UiWorkKind.editorHelpBuild,
  UiWorkKind.editorStatusBuild,
  UiWorkKind.editorHostBuild,
  UiWorkKind.readerActionsBuild,
];

Widget _surface(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(child: SizedBox(width: 240, height: 50, child: child)),
);

List<Map<String, dynamic>> _work(List<Map<String, dynamic>> records) => [
  for (final record in records)
    for (final sample in record['uiWorkSamples'] as List<dynamic>? ?? [])
      sample as Map<String, dynamic>,
];

Future<void> _capture(
  List<Map<String, dynamic>> records,
  Future<void> Function() body,
) => runZoned(
  () async {
    FrameDiagnostics.start();
    try {
      await body();
    } finally {
      FrameDiagnostics.stop();
    }
  },
  zoneSpecification: ZoneSpecification(
    print: (_, _, _, line) =>
        records.add(jsonDecode(line) as Map<String, dynamic>),
  ),
);

class _BuildProbe extends StatefulWidget {
  const _BuildProbe({required this.onBuild, this.label = 'first', super.key});
  final VoidCallback onBuild;
  final String label;

  @override
  State<_BuildProbe> createState() => _BuildProbeState();
}

class _BuildProbeState extends State<_BuildProbe> {
  int localRevision = 0;

  void updateLocally() => setState(() => localRevision++);

  @override
  Widget build(BuildContext context) {
    widget.onBuild();
    return Text('${widget.label}:$localRevision');
  }
}

class _FailingBuild extends StatelessWidget {
  const _FailingBuild();

  @override
  Widget build(BuildContext context) =>
      throw StateError('visible descendant build failure');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('normal builds return identical children for every build scope', () {
    const child = SizedBox(width: 120, height: 32);
    for (final kind in _buildKinds) {
      expect(sampleEditorBuild(kind: kind, child: child), same(child));
    }
    expect(
      sampleEditorHeader(
        buildKind: UiWorkKind.editorFormatsBuild,
        layoutKind: UiWorkKind.editorFormatsLayout,
        paintKind: UiWorkKind.editorFormatsPaint,
        child: child,
      ),
      same(child),
    );
  }, skip: FrameDiagnostics.enabled && FrameDiagnostics.rawFrames);

  testWidgets('build scope preserves geometry, semantics and live callbacks', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      var oldTaps = 0;
      var currentTaps = 0;
      const key = ValueKey('build-scope-action');
      Widget action(VoidCallback callback) => Semantics(
        key: key,
        container: true,
        button: true,
        label: 'Build scope action',
        onTap: callback,
        child: GestureDetector(
          excludeFromSemantics: true,
          onTap: callback,
          child: const ColoredBox(color: Color(0xff123456)),
        ),
      );
      await tester.pumpWidget(_surface(action(() => oldTaps++)));
      final originalRect = tester.getRect(find.byKey(key));
      await tester.pumpWidget(
        _surface(
          sampleEditorBuild(
            kind: UiWorkKind.editorControlsBuild,
            child: action(() => oldTaps++),
          ),
        ),
      );
      final actionElement = tester.element(find.byKey(key));
      await tester.tap(find.byKey(key));
      expect(oldTaps, 1);
      await tester.pumpWidget(
        _surface(
          sampleEditorBuild(
            kind: UiWorkKind.editorControlsBuild,
            child: action(() => currentTaps++),
          ),
        ),
      );
      expect(tester.element(find.byKey(key)), same(actionElement));
      expect(tester.getRect(find.byKey(key)), originalRect);
      expect(
        tester.getSemantics(find.byKey(key)),
        matchesSemantics(
          label: 'Build scope action',
          isButton: true,
          hasTapAction: true,
          textDirection: TextDirection.ltr,
        ),
      );
      await tester.tap(find.byKey(key));
      expect(oldTaps, 1);
      expect(currentTaps, 1);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'raw build scope measures mounting and synchronous updates only',
    (tester) async {
      final records = <Map<String, dynamic>>[];
      final frames = <int>[];
      final probeKey = GlobalKey<_BuildProbeState>();
      void observeBuild() {
        frames.add(ui.PlatformDispatcher.instance.frameData.frameNumber);
        FrameDiagnostics.recordUiWork(UiWorkKind.composerBuild, count: 1);
      }

      await _capture(records, () async {
        final start = DateTime.now().toUtc().microsecondsSinceEpoch;
        await tester.pumpWidget(
          _surface(
            sampleEditorBuild(
              kind: UiWorkKind.editorBodyBuild,
              child: _BuildProbe(key: probeKey, onBuild: observeBuild),
            ),
          ),
        );
        final state = probeKey.currentState!;
        FrameDiagnostics.report();
        final initial = _work(records);
        expect(initial.map((s) => s['kind']), [
          'composerBuild',
          'editorBodyBuild',
        ]);
        final sample = initial.last;
        expect(sample['startedUnixMicros'], greaterThanOrEqualTo(start));
        expect(
          sample['startedUnixMicros'],
          lessThanOrEqualTo(DateTime.now().toUtc().microsecondsSinceEpoch),
        );
        expect(sample['durationMicros'], greaterThanOrEqualTo(0));
        expect(sample['frameNumber'], frames.single);
        expect(sample['count'], 1);
        expect(sample.containsKey('width'), isFalse);
        expect(sample.containsKey('height'), isFalse);

        await tester.pumpWidget(
          _surface(
            sampleEditorBuild(
              kind: UiWorkKind.editorBodyBuild,
              child: _BuildProbe(
                key: probeKey,
                label: 'updated',
                onBuild: observeBuild,
              ),
            ),
          ),
        );
        FrameDiagnostics.report();
        expect(probeKey.currentState, same(state));
        expect(find.text('updated:0'), findsOneWidget);
        expect(_work(records).map((s) => s['kind']), [
          'composerBuild',
          'editorBodyBuild',
          'composerBuild',
          'editorBodyBuild',
        ]);

        state.updateLocally();
        await tester.pump();
        FrameDiagnostics.report();
        expect(find.text('updated:1'), findsOneWidget);
        expect(
          _work(records).where((s) => s['kind'] == 'editorBodyBuild'),
          hasLength(2),
        );
        expect(
          _work(records).where((s) => s['kind'] == 'composerBuild'),
          hasLength(3),
        );
        final count = _work(records).length;
        await tester.pump();
        FrameDiagnostics.report();
        expect(_work(records), hasLength(count));
      });
      expect(tester.takeException(), isNull);
    },
    skip: !FrameDiagnostics.enabled || !FrameDiagnostics.rawFrames,
  );

  testWidgets('nested build samples end before deferred LayoutBuilder work', (
    tester,
  ) async {
    final records = <Map<String, dynamic>>[];
    await _capture(records, () async {
      await tester.pumpWidget(
        _surface(
          sampleEditorBuild(
            kind: UiWorkKind.editorFormatsBuild,
            child: sampleEditorBuild(
              kind: UiWorkKind.editorMediaBuild,
              child: LayoutBuilder(
                builder: (context, bounds) {
                  FrameDiagnostics.recordUiWork(
                    UiWorkKind.composerBuild,
                    count: 1,
                  );
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      );
      FrameDiagnostics.report();
      final work = _work(records);
      expect(work.map((s) => s['kind']), [
        'editorMediaBuild',
        'editorFormatsBuild',
        'composerBuild',
      ]);
      final inner = work[0];
      final outer = work[1];
      expect(
        outer['startedUnixMicros'],
        lessThanOrEqualTo(inner['startedUnixMicros']),
      );
      expect(
        outer['durationMicros'],
        greaterThanOrEqualTo(inner['durationMicros']),
      );
      expect(outer['frameNumber'], inner['frameNumber']);
    });
    expect(tester.takeException(), isNull);
  }, skip: !FrameDiagnostics.enabled || !FrameDiagnostics.rawFrames);

  testWidgets('a descendant build failure remains visible and can recover', (
    tester,
  ) async {
    final records = <Map<String, dynamic>>[];
    await _capture(records, () async {
      await tester.pumpWidget(
        _surface(
          sampleEditorBuild(
            kind: UiWorkKind.editorHeadingBuild,
            child: const _FailingBuild(),
          ),
        ),
      );
      final error = tester.takeException();
      expect(error, isA<StateError>());
      expect(error.toString(), contains('visible descendant build failure'));
      if (FrameDiagnostics.enabled && FrameDiagnostics.rawFrames) {
        FrameDiagnostics.report();
        final measured = _work(records)
            .where((sample) => sample['kind'] == 'editorHeadingBuild');
        expect(measured, hasLength(1));
        expect(measured.single['durationMicros'], greaterThanOrEqualTo(0));
      }
      await tester.pumpWidget(
        _surface(
          sampleEditorBuild(
            kind: UiWorkKind.editorHeadingBuild,
            child: const Text('recovered'),
          ),
        ),
      );
      expect(find.text('recovered'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
