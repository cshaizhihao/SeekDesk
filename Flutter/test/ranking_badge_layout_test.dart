// ignore: deprecated_member_use
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seekdesk_flutter/widgets/sidebar_rankings.dart';

void main() {
  testWidgets('top three badges fit the narrow sidebar without wrapping', (
    tester,
  ) async {
    await tester.pumpWidget(
      CupertinoApp(
        home: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final rank in [1, 2, 3])
                SizedBox(width: 40, child: RankingPositionBadge(position: rank)),
            ],
          ),
        ),
      ),
    );
    for (final rank in [1, 2, 3]) {
      final richText = find.descendant(
        of: find.text('🔥 $rank'),
        matching: find.byType(RichText),
      );
      final paragraph = tester.renderObject<RenderParagraph>(richText);
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(
        paragraph.getMaxIntrinsicWidth(double.infinity),
        lessThanOrEqualTo(paragraph.size.width),
      );
      expect(paragraph.size.height, lessThan(25));
    }
    expect(tester.takeException(), isNull);
  });
}
