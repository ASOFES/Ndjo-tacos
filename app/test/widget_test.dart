import 'package:flutter_test/flutter_test.dart';
import 'package:ndjo_tacos/api.dart';
import 'package:ndjo_tacos/main.dart';
import 'package:ndjo_tacos/session.dart';

void main() {
  testWidgets('affiche l ecran de demarrage NDJO TACOS', (tester) async {
    await tester.pumpWidget(NdjoApp(session: Session(Api())));
    expect(find.text('NDJO TACOS'), findsOneWidget);
  });
}
