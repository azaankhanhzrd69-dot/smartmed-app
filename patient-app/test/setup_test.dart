import 'package:flutter_test/flutter_test.dart';
import 'package:patientify_patient_app/main.dart';

void main() {
  testWidgets('shows setup guidance when Supabase configuration is missing', (
    tester,
  ) async {
    await tester.pumpWidget(const SetupRequiredApp());

    expect(
      find.textContaining('SUPABASE_PUBLISHABLE_KEY'),
      findsOneWidget,
    );
  });
}
