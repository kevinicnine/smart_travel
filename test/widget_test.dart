import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_travel/main.dart';
import 'package:smart_travel/pages/login_page.dart';
import 'package:smart_travel/pages/select_interest_page.dart';
import 'package:smart_travel/pages/home_page.dart';
import 'package:smart_travel/state/user_state.dart';

void main() {
  testWidgets('SmartTravelApp shows StartPage', (tester) async {
    await tester.pumpWidget(const SmartTravelApp());

    expect(find.text('智慧旅遊系統'), findsOneWidget);
    expect(find.text("Let's Start!"), findsOneWidget);
  });

  testWidgets('LoginPage navigates to SelectInterestPage when captcha matches', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));

    final loginState = tester.state<State>(find.byType(LoginPage));
    final captcha = (loginState as dynamic).captchaText as String;

    final captchaField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.hintText == '輸入右方文字',
    );
    await tester.enterText(captchaField, captcha);

    await tester.tap(find.text('Log In'));
    await tester.pumpAndSettle();

    expect(find.byType(SelectInterestPage), findsOneWidget);
  });

  testWidgets('HomePage greets with saved user name', (tester) async {
    UserState.updateName('小明');
    addTearDown(() => UserState.displayName = null);

    await tester.pumpWidget(const MaterialApp(
      home: HomePage(
        selectedInterestIds: [],
      ),
    ));

    expect(find.text('Hi! 小明'), findsOneWidget);
  });

  testWidgets('SelectInterestPage navigates to HomePage after selecting interests', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SelectInterestPage()));

    await tester.tap(find.text('國家公園'));
    await tester.pump();
    await tester.tap(find.text('湖泊/河川'));
    await tester.pump();
    await tester.tap(find.text('海灘'));
    await tester.pump();

    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    expect(find.byType(HomePage), findsOneWidget);
  });
}
