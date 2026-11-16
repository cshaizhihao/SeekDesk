// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/widgets/reader_markdown_workspace.dart';

void main() {
  testWidgets(
    'control row fills bounded width and preserves height constraints',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const childKey = ValueKey('control-row-child');
      for (final (constraints, expected) in const [
        (BoxConstraints(maxWidth: 412), Size(412, 37)),
        (BoxConstraints(minWidth: 300, maxWidth: 900), Size(900, 37)),
        (BoxConstraints.tightFor(width: 560, height: 60), Size(560, 60)),
        (BoxConstraints(maxWidth: 412, maxHeight: 20), Size(412, 20)),
      ]) {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: UnconstrainedBox(
                child: ConstrainedBox(
                  constraints: constraints,
                  child: const ReaderMarkdownControlRow(
                    child: SizedBox(key: childKey, height: 37),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.getSize(find.byKey(childKey)), expected);
        expect(tester.getSize(find.byType(ReaderMarkdownControlRow)), expected);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'unbounded control row uses 700 without violating a larger minimum',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const childKey = ValueKey('unbounded-control-row-child');
      for (final (minimum, expectedWidth) in const [
        (0.0, 700.0),
        (650.0, 700.0),
        (980.0, 980.0),
      ]) {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: UnconstrainedBox(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: minimum),
                  child: const ReaderMarkdownControlRow(
                    child: SizedBox(key: childKey, height: 37),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.getSize(find.byKey(childKey)), Size(expectedWidth, 37));
        expect(
          tester.getSize(find.byType(ReaderMarkdownControlRow)),
          Size(expectedWidth, 37),
        );
        expect(tester.takeException(), isNull);
      }
    },
  );
}
