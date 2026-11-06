// Drives the app's real screens through a rep's day against a fake Odoo.
//
// To save a picture of each screen to docs/screenshots/:
//   BEATPRO_SCREENSHOTS=1 flutter test test/app_flow_test.dart --update-goldens
import 'dart:io';

import 'package:beatpro/src/app.dart';
import 'package:beatpro/src/core/local_db.dart';
import 'package:beatpro/src/core/models.dart';
import 'package:beatpro/src/core/repository.dart';
import 'package:beatpro/src/core/services.dart';
import 'package:beatpro/src/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:beatpro/src/widgets/scanner.dart';

import 'support/fake_odoo.dart';
import 'support/fake_scanner.dart';

Future<void> _loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final dir = '$root/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final file = File('$dir/$f');
      if (file.existsSync()) loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  }

  await load('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
  // The app's own typeface, from its assets.
  final manrope = FontLoader('Manrope');
  for (final w in ['Medium', 'SemiBold', 'Bold', 'ExtraBold']) {
    manrope.addFont(Future.value(ByteData.sublistView(File('assets/fonts/Manrope-$w.ttf').readAsBytesSync())));
  }
  await manrope.load();
}

Future<void> _loadImages(WidgetTester tester) async {
  // Image files decode outside the test clock: wait for them before a screenshot.
  await tester.runAsync(() async {
    for (final e in find.byType(Image).evaluate()) {
      await precacheImage((e.widget as Image).image, e);
    }
  });
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    await _loadFonts();
  });

  testWidgets("a rep's day in the app", (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final odoo = FakeOdoo();
    final db = await LocalDb.open(factory: databaseFactoryFfiNoIsolate, path: inMemoryDatabasePath);
    final container = ProviderContainer(overrides: [
      localDbProvider.overrideWithValue(db),
      credentialStoreProvider.overrideWithValue(MemoryCredentialStore()),
      locationProvider.overrideWithValue(const FixedLocationService(GeoPoint(19.1136, 72.8697))),
      httpClientProvider.overrideWithValue(odoo.client),
    ]);
    addTearDown(container.dispose);

    const appKey = Key('app');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const RepaintBoundary(key: appKey, child: BeatproApp()),
    ));
    await tester.pumpAndSettle();
    var shot = 0;
    final saveScreens = Platform.environment['BEATPRO_SCREENSHOTS'] != null;
    Future<void> screen(String name) async {
      await tester.pumpAndSettle();
      shot++;
      if (!saveScreens) return;
      await _loadImages(tester);
      await expectLater(
        find.byKey(appKey),
        matchesGoldenFile('../docs/screenshots/${shot.toString().padLeft(2, '0')}-$name.png'),
      );
    }

    // Sign in.
    expect(find.text("Sign in to your company's Odoo"), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Odoo address'), 'https://mumbai.example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Email or username'), 'ravi@beatpro.test');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'ravi123');
    await screen('sign-in');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'wrong');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Wrong login or password.'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'ravi123');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    // Odoo made a key for this phone; the password is not kept.
    final session = container.read(sessionProvider)!;
    expect(session.apiKey, 'k' * 40);
    expect(session.login, 'ravi@beatpro.test');
    expect(session.toJson().values, isNot(contains('ravi123')));
    expect(odoo.signIns.last['device'], matches(RegExp(r'· [0-9a-f]{6}$')));
    expect(odoo.signIns.last['header_db'], isNull, reason: 'no database entered');

    // Home.
    expect(find.text('My Day'), findsOneWidget);
    expect(find.text('0/4'), findsOneWidget);
    expect(find.text('4 shops left today'), findsOneWidget);
    await screen('home');

    // Today's route.
    await tester.tap(find.text('Route'));
    await screen('route');
    expect(find.text('Sharma General Store'), findsOneWidget);

    // Customer, then check in.
    await tester.tap(find.text('Sharma General Store'));
    await screen('customer');
    expect(find.text('INV/2026/00042'), findsOneWidget);
    await tester.tap(find.text('Check in'));
    await screen('visit');
    expect(find.text('Checked in'), findsOneWidget);
    expect(find.textContaining('m from the shop pin'), findsOneWidget);

    // Take an order: 2 cases of Maggi at the customer's price, 1 box of Parle-G.
    await tester.tap(find.text('Take order'));
    await tester.pumpAndSettle();
    expect(find.text('₹560.00'), findsOneWidget, reason: "Maggi at the customer's price list price");
    Finder addButtonFor(String product) => find.descendant(
        of: find.widgetWithText(ListTile, product), matching: find.widgetWithText(OutlinedButton, 'Add'));
    await tester.tap(addButtonFor('Maggi Noodles (Case of 48)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More').first);
    await tester.tap(addButtonFor('Parle-G Biscuits (Box of 24)'));
    await screen('catalog');
    await tester.tap(find.textContaining('Review'));
    await screen('cart');
    // 2 × 560 + 240 = 1,360 before tax; 18% GST = 244.80.
    expect(find.text('₹1,360.00'), findsOneWidget);
    expect(find.text('₹244.80'), findsOneWidget);
    await tester.tap(find.textContaining('Place order'));
    await screen('order');
    expect(find.text('Waiting to sync'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Collect the overdue invoice by UPI.
    await tester.tap(find.text('Collect payment'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('INV/2026/00042'));
    await tester.tap(find.text('UPI'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'UPI transaction ID (optional)'), '430912345678');
    expect(find.text('Cheque'), findsOneWidget, reason: 'payment methods come from Odoo');
    await screen('payment');
    expect(find.text('Record ₹1,200.00 by UPI'), findsOneWidget);
    await tester.tap(find.text('Record ₹1,200.00 by UPI'));
    await tester.pumpAndSettle();
    expect(find.text('IN THIS VISIT'), findsOneWidget);
    expect(find.text('UPI payment'), findsOneWidget);
    await screen('visit-with-order');

    // Check out: the visit, order and payment go to Odoo.
    await tester.tap(find.text('Check out'));
    await tester.pumpAndSettle();
    await screen('check-out');
    await tester.tap(find.widgetWithText(FilledButton, 'Check out').last); // the button in the sheet
    await tester.pumpAndSettle();

    expect(odoo.uploaded['beatpro.visit']!.single['result'], 'order');
    expect(odoo.uploaded['beatpro.visit']!.single['check_in_latitude'], 19.1136);
    final orderVals = odoo.uploaded['sale.order']!.single;
    expect(orderVals['partner_id'], 8);
    expect((orderVals['order_line'] as List).length, 2);
    final paymentVals = odoo.uploaded['account.payment']!.single;
    expect(paymentVals['amount'], 1200.0);
    expect(paymentVals['payment_method_line_id'], 32, reason: "the UPI method set up in Odoo");
    expect(paymentVals['invoice_ids'], [77]);
    expect(paymentVals['beatpro_reference'], '430912345678');

    // Close the day.
    container.read(routerProvider).push('/day-close');
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Distance travelled'), '23');
    await screen('day-close');
    await tester.tap(find.text('Close day and send to supervisor'));
    await tester.pumpAndSettle();
    expect(find.text('Today is closed'), findsOneWidget);
    expect(odoo.uploaded['beatpro.day.close']!.single['distance_km'], 23.0);
    expect(odoo.calls, contains('beatpro.day.close.action_close'));

    // Orders tab shows Odoo's confirmation.
    container.read(routerProvider).go('/orders');
    await screen('orders');
    expect(find.text('Confirmed'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets('customer pays an invoice online with a QR code', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final odoo = FakeOdoo();
    final db = (await tester.runAsync(() => LocalDb.open(
          factory: databaseFactoryFfiNoIsolate,
          path: '${Directory.systemTemp.createTempSync().path}/online.db',
        )))!;
    final container = ProviderContainer(overrides: [
      localDbProvider.overrideWithValue(db),
      credentialStoreProvider.overrideWithValue(MemoryCredentialStore()),
      locationProvider.overrideWithValue(const FixedLocationService(GeoPoint(19.1136, 72.8697))),
      httpClientProvider.overrideWithValue(odoo.client),
    ]);
    addTearDown(container.dispose);
    const appKey = Key('app');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const RepaintBoundary(key: appKey, child: BeatproApp()),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Odoo address'), 'https://mumbai.example.com');
    // Users with two-step sign-in paste an API key instead.
    await tester.tap(find.text('Two-step sign-in? Use an API key'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'API key'), 'k' * 40);
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    container.read(routerProvider).push('/payment/new?customer=srv%3A8');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pay online'));
    await tester.pumpAndSettle();
    expect(find.text('Choose an invoice'), findsOneWidget);
    await tester.tap(find.text('INV/2026/00042'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show QR code'));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('Pay with Razorpay'), findsOneWidget);
    await tester.ensureVisible(find.text('Check payment'));
    await tester.pumpAndSettle();
    expect(odoo.calls, contains('account.payment.beatpro_payment_link'));
    if (Platform.environment['BEATPRO_SCREENSHOTS'] != null) {
      await expectLater(find.byKey(appKey), matchesGoldenFile('../docs/screenshots/14-pay-online.png'));
    }

    await tester.tap(find.text('Check payment'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Not paid yet'), findsOneWidget);
    odoo.onlinePaid = true;
    await tester.ensureVisible(find.text('Check payment'));
    await tester.tap(find.text('Check payment'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Paid online'), findsOneWidget);
    // Nothing was recorded on the phone: the provider's payment is in Odoo.
    expect(odoo.uploaded['account.payment'], isNull);

    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets('a van day: load, deliver from the van, take goods back, unload', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final odoo = FakeOdoo()..withVan = true;
    final db = await LocalDb.open(factory: databaseFactoryFfiNoIsolate, path: inMemoryDatabasePath);
    final container = ProviderContainer(overrides: [
      localDbProvider.overrideWithValue(db),
      credentialStoreProvider.overrideWithValue(MemoryCredentialStore()),
      locationProvider.overrideWithValue(const FixedLocationService(GeoPoint(19.1155, 72.8722))),
      httpClientProvider.overrideWithValue(odoo.client),
    ]);
    addTearDown(container.dispose);
    const appKey = Key('app');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const RepaintBoundary(key: appKey, child: BeatproApp()),
    ));
    await tester.pumpAndSettle();
    final saveScreens = Platform.environment['BEATPRO_SCREENSHOTS'] != null;
    Future<void> screen(String name) async {
      tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first).clearSnackBars();
      await tester.pumpAndSettle();
      if (!saveScreens) return;
      await _loadImages(tester);
      await expectLater(find.byKey(appKey), matchesGoldenFile('../docs/screenshots/$name.png'));
    }

    await tester.enterText(find.widgetWithText(TextFormField, 'Odoo address'), 'https://mumbai.example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Email or username'), 'ravi@beatpro.test');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'ravi123');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    final router = container.read(routerProvider);
    final repo = container.read(repositoryProvider);

    // Morning: the van is empty; ask the storekeeper for today's suggested load.
    await tester.scrollUntilVisible(find.text('MH 02 AB 4521'), 200);
    expect(find.text('Empty · load the van before you leave'), findsOneWidget);
    router.push('/van/load');
    await tester.pumpAndSettle();
    expect(find.text('36 cases'), findsOneWidget);
    await screen('15-van-load');
    await tester.tap(find.text('Send load request · 36 cases'));
    await tester.pumpAndSettle();
    final load = odoo.uploaded['beatpro.van.transfer.load']!.single;
    expect((load['line_ids'] as List).length, 3);
    expect((await repo.vanStock()).loadWaiting, isTrue);

    // The storekeeper loads the van; the next sync brings the stock.
    odoo.storekeeperLoads();
    await container.read(syncControllerProvider.notifier).run();
    router.push('/van');
    await tester.pumpAndSettle();
    expect(find.text('36 cases'), findsOneWidget);
    expect(find.text('₹15,920.00 at sale price'), findsOneWidget);
    await screen('16-van-stock');

    // At Patel Kirana: 6 Parle-G from the van, 1 Surf Excel the van doesn't carry.
    final visit = await repo.startVisit('srv:9');
    container.read(dataVersionProvider.notifier).bump();
    router.push('/order/new?customer=srv%3A9&visit=${visit.uuid}');
    await tester.pumpAndSettle();
    Finder inTile(String product, Finder f) => find.descendant(of: find.widgetWithText(ListTile, product), matching: f);
    await tester.tap(inTile('Parle-G Biscuits (Box of 24)', find.widgetWithText(OutlinedButton, 'Add')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      await tester.tap(inTile('Parle-G Biscuits (Box of 24)', find.byTooltip('More')));
      await tester.pump();
    }
    await tester.ensureVisible(find.text('Surf Excel 1kg (Case of 12)'));
    await tester.pumpAndSettle();
    await tester.tap(inTile('Surf Excel 1kg (Case of 12)', find.widgetWithText(OutlinedButton, 'Add')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Review'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Van now, the rest from the warehouse'), 200,
        scrollable: find.byType(Scrollable).last);
    expect(find.textContaining('Not possible: Surf Excel'), findsOneWidget);
    await screen('17-delivery-choice');
    await tester.tap(find.text('Place order · deliver 1 item now'));
    await tester.pumpAndSettle();
    expect((await repo.vanStock()).leftOf(1), 12, reason: 'the van shows the boxes handed over straight away');

    // The shop gives back 2 expired butter packs and 3 boxes of biscuits that don't sell.
    router.push('/return/new?customer=srv%3A9&visit=${visit.uuid}');
    await tester.pumpAndSettle();
    Finder inCard(String product, Finder f) => find.descendant(of: find.widgetWithText(Card, product), matching: f);
    await tester.tap(find.text('+ Add product'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Amul Butter 100g (Pack of 20)'));
    await tester.pumpAndSettle();
    await tester.tap(inCard('Amul Butter 100g (Pack of 20)', find.byTooltip('More')));
    await tester.pump();
    await tester.tap(inCard('Amul Butter 100g (Pack of 20)', find.text('Expired')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ Add product'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Parle-G Biscuits (Box of 24)').last);
    await tester.pumpAndSettle();
    await tester.tap(inCard('Parle-G Biscuits (Box of 24)', find.byTooltip('More')));
    await tester.pump();
    await tester.tap(inCard('Parle-G Biscuits (Box of 24)', find.byTooltip('More')));
    await tester.pump();
    await tester.tap(inCard('Parle-G Biscuits (Box of 24)', find.text('Not selling')));
    await tester.pumpAndSettle();
    expect(find.text('Goes back into the van, can be sold again'), findsOneWidget);
    await screen('18-shop-return');
    await tester.tap(find.text('Take back 5 items · ₹1,680.00 credit'));
    await tester.pumpAndSettle();

    await repo.checkOut(visit.uuid, result: VisitResult.order);
    await container.read(syncControllerProvider.notifier).run();
    final order = odoo.uploaded['sale.order']!.single;
    expect(order['beatpro_delivery_mode'], 'split');
    final returned = (odoo.uploaded['beatpro.shop.return']!.single['line_ids'] as List)
        .map((l) => (l as List)[2] as Map<String, dynamic>)
        .toList();
    expect([for (final l in returned) (l['product_id'], l['qty'], l['reason'], l['resellable'])],
        [(4, 2.0, 'expired', false), (1, 3.0, 'not_selling', true)]);

    // Evening: 15 boxes should be left (18 − 6 + 3); one is missing.
    router.push('/van/unload');
    await tester.pumpAndSettle();
    final parleCount = find.descendant(
        of: find.ancestor(of: find.text('Parle-G Biscuits (Box of 24)'), matching: find.byType(Container)).first,
        matching: find.byType(TextField));
    expect(tester.widget<TextField>(parleCount).controller!.text, '15');
    await tester.enterText(parleCount, '14');
    await tester.pumpAndSettle();
    expect(find.text('1 short: Parle-G Biscuits (Box of 24)'), findsOneWidget);
    expect(find.text('2 items'), findsOneWidget, reason: 'damaged returns go to the damaged area');
    await tester.tap(find.text('Send unload · 32 cases'));
    await tester.pumpAndSettle();
    expect(odoo.uploaded['beatpro.van.transfer.unload'], isNull, reason: 'a shortage needs a note');
    await tester.enterText(find.byType(TextField).last, 'One box torn, given to the shop as a free sample.');
    await tester.pumpAndSettle();
    await screen('19-van-unload');
    await tester.tap(find.text('Send unload · 32 cases'));
    await tester.pumpAndSettle();
    await container.read(syncControllerProvider.notifier).run();
    final unload = odoo.uploaded['beatpro.van.transfer.unload']!.single;
    expect(unload['note'], 'One box torn, given to the shop as a free sample.');
    final parle = (unload['line_ids'] as List).map((l) => (l as List)[2] as Map<String, dynamic>).firstWhere((l) => l['product_id'] == 1);
    expect((parle['qty'], parle['qty_expected']), (14.0, 15.0));

    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets('a supervisor opens the Van Sales Dashboard', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final odoo = FakeOdoo()..supervisor = true;
    final db = await LocalDb.open(factory: databaseFactoryFfiNoIsolate, path: inMemoryDatabasePath);
    final container = ProviderContainer(overrides: [
      localDbProvider.overrideWithValue(db),
      credentialStoreProvider.overrideWithValue(MemoryCredentialStore()),
      locationProvider.overrideWithValue(const FixedLocationService(null)),
      httpClientProvider.overrideWithValue(odoo.client),
    ]);
    addTearDown(container.dispose);
    const appKey = Key('app');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const RepaintBoundary(key: appKey, child: BeatproApp()),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Odoo address'), 'https://mumbai.example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Database (optional)'), 'mumbai');
    await tester.enterText(find.widgetWithText(TextFormField, 'Email or username'), 'ravi@beatpro.test');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'ravi123');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(odoo.signIns.last['header_db'], 'mumbai', reason: 'Odoo picks the database from this header');
    expect(find.text('Van Sales Dashboard', skipOffstage: false), findsOneWidget, reason: 'a card on My Day');
    container.read(routerProvider).push('/dashboard');
    await tester.pumpAndSettle();
    expect(find.text('₹75,484.00'), findsWidgets);
    expect(find.text('↑ 12.5% vs last period'), findsOneWidget);
    expect(find.text('↓ 2.0% vs last period'), findsOneWidget);
    if (Platform.environment['BEATPRO_SCREENSHOTS'] != null) {
      await _loadImages(tester);
      await expectLater(find.byKey(appKey), matchesGoldenFile('../docs/screenshots/20-dashboard.png'));
    }
    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();
    expect(find.text('243'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Farah Khan: unload 1 short'), 300, scrollable: find.byType(Scrollable).last);
    expect(find.text('72%'), findsOneWidget);
    expect(odoo.calls.where((c) => c == 'beatpro.theme.get_sales_dashboard').length, 2);

    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets('scanning barcodes adds products to orders, loads, returns and counts', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final odoo = FakeOdoo()..withVan = true;
    final scanner = FakeBarcodeScanner();
    final db = await LocalDb.open(factory: databaseFactoryFfiNoIsolate, path: inMemoryDatabasePath);
    final container = ProviderContainer(overrides: [
      localDbProvider.overrideWithValue(db),
      credentialStoreProvider.overrideWithValue(MemoryCredentialStore()),
      locationProvider.overrideWithValue(const FixedLocationService(null)),
      httpClientProvider.overrideWithValue(odoo.client),
      barcodeScannerProvider.overrideWithValue(scanner),
    ]);
    addTearDown(container.dispose);
    const appKey = Key('app');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const RepaintBoundary(key: appKey, child: BeatproApp()),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Odoo address'), 'https://mumbai.example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Email or username'), 'ravi@beatpro.test');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'ravi123');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    final router = container.read(routerProvider);
    final repo = container.read(repositoryProvider);

    // Morning load: scan two boxes of Maggi and one unknown code.
    router.push('/van/load');
    await tester.pumpAndSettle();
    scanner.queue.addAll(['8901058851298', '8901058851298', '0000000000000']);
    await tester.tap(find.byTooltip('Scan barcodes'));
    await tester.pumpAndSettle();
    expect(scanner.titles.last, 'Scan products to load');
    expect(scanner.feedback.map((f) => f.ok), [true, true, false]);
    expect(scanner.feedback.last.message, contains('No product with barcode 0000000000000'));
    expect(find.text('Send load request · 38 cases'), findsOneWidget, reason: '36 suggested + 2 scanned');
    await tester.tap(find.text('Send load request · 38 cases'));
    await tester.pumpAndSettle();
    final loadLines = (odoo.uploaded['beatpro.van.transfer.load']!.single['line_ids'] as List)
        .map((l) => (l as List)[2] as Map<String, dynamic>);
    expect(loadLines.firstWhere((l) => l['product_id'] == 2)['qty'], 2.0);
    odoo.storekeeperLoads();
    await container.read(syncControllerProvider.notifier).run();

    // An order: scan Parle-G three times with the camera, then a handheld scanner types Tata Salt's code.
    final visit = await repo.startVisit('srv:9');
    router.push('/order/new?customer=srv%3A9&visit=${visit.uuid}');
    await tester.pumpAndSettle();
    scanner.queue.addAll(['8901719101038', '8901719101038', '8901719101038']);
    await tester.tap(find.byTooltip('Scan barcodes'));
    await tester.pumpAndSettle();
    expect(scanner.feedback.last.message, 'Added Parle-G Biscuits (Box of 24) · 3 in the order');
    await tester.enterText(find.widgetWithText(TextField, 'Search or scan products'), '8904043901015');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Added Tata Salt 1kg (Bag of 10) · 1 in the order'), findsOneWidget);
    expect(find.text('4 items'), findsOneWidget);
    if (Platform.environment['BEATPRO_SCREENSHOTS'] != null) {
      await _loadImages(tester);
      await expectLater(find.byKey(appKey), matchesGoldenFile('../docs/screenshots/21-scanned-order.png'));
    }
    await tester.tap(find.textContaining('Review'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Deliver now ·'));
    await tester.pumpAndSettle();

    // Goods taken back: scanning the same pack twice makes one line of 2.
    router.push('/return/new?customer=srv%3A9&visit=${visit.uuid}');
    await tester.pumpAndSettle();
    scanner.queue.addAll(['AB20', '8901262150064']);
    await tester.tap(find.byTooltip('Scan barcodes'));
    await tester.pumpAndSettle();
    expect(scanner.feedback.last.message, 'Amul Butter 100g (Pack of 20) · 2 taken back');
    expect(find.text('Take back 2 items · ₹960.00 credit'), findsOneWidget);
    await tester.tap(find.text('Take back 2 items · ₹960.00 credit'));
    await tester.pumpAndSettle();
    await repo.checkOut(visit.uuid, result: VisitResult.order);
    await container.read(syncControllerProvider.notifier).run();
    final order = odoo.uploaded['sale.order']!.single;
    expect([for (final l in order['order_line'] as List) ((l as List)[2] as Map)['product_uom_qty']], [3, 1]);

    // Day end: count Maggi by scanning (2 left, scanned 2) — the first scan replaces what was filled in.
    router.push('/van/unload');
    await tester.pumpAndSettle();
    scanner.queue.addAll(['8901058851298', '8901058851298']);
    await tester.tap(find.byTooltip('Scan barcodes'));
    await tester.pumpAndSettle();
    expect(scanner.titles.last, 'Count by scanning');
    expect(scanner.feedback.last.message, 'Maggi Noodles (Case of 48) · counted 2 of 2');
    scanner.queue.add('8901030704116');
    await tester.tap(find.byTooltip('Scan barcodes'));
    await tester.pumpAndSettle();
    expect(scanner.feedback.last.ok, isFalse, reason: "Surf Excel isn't in the van");

    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets('work done offline waits on the phone, then syncs', (tester) async {
    final odoo = FakeOdoo();
    // Real file access must run outside the test's fake clock.
    final db = (await tester.runAsync(() => LocalDb.open(
          factory: databaseFactoryFfiNoIsolate,
          path: '${Directory.systemTemp.createTempSync().path}/offline.db',
        )))!;
    final container = ProviderContainer(overrides: [
      localDbProvider.overrideWithValue(db),
      credentialStoreProvider.overrideWithValue(MemoryCredentialStore()),
      locationProvider.overrideWithValue(const FixedLocationService(null)),
      httpClientProvider.overrideWithValue(odoo.client),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const BeatproApp()));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Odoo address'), 'https://mumbai.example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Email or username'), 'ravi@beatpro.test');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'ravi123');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    odoo.offline = true;
    final repo = container.read(repositoryProvider);
    final visit = await repo.startVisit('srv:9');
    await repo.checkOut(visit.uuid, result: VisitResult.noOrder, noOrderReason: 'enough_stock');
    final report = await container.read(syncControllerProvider.notifier).run();
    expect(report!.offlineMessage, isNotNull);
    expect(await repo.pendingCount(), 1);
    expect(odoo.uploaded, isEmpty);

    // Signing in again (e.g. after the key expired) keeps the work on the phone.
    odoo.offline = false;
    container.read(routerProvider).push('/sign-in-again');
    await tester.pumpAndSettle();
    expect(find.text('Sign in again'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'ravi123');
    await tester.ensureVisible(find.text('Sign in'));
    await tester.pumpAndSettle();
    final loginsBefore = odoo.signIns.length;
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(odoo.signIns.length, loginsBefore + 1);
    expect(find.text('Sign in again'), findsNothing, reason: 'back where the rep was');
    expect(await tester.runAsync(() => repo.pendingCount()), 1);

    odoo.offline = false;
    final second = await container.read(syncControllerProvider.notifier).run();
    expect(second!.ok, isTrue);
    expect(await repo.pendingCount(), 0);
    expect(odoo.uploaded['beatpro.visit']!.single['no_order_reason'], 'enough_stock');

    await tester.pumpWidget(const SizedBox());
    await db.close();
  });
}
