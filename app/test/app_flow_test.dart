// Drives the app's real screens through a rep's day against a fake Odoo.
//
// To save a picture of each screen to docs/screenshots/:
//   BEATPRO_SCREENSHOTS=1 flutter test test/app_flow_test.dart --update-goldens
import 'dart:convert';
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
import 'support/fake_photos.dart';
import 'support/fake_printer.dart';
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
  final arabic = FontLoader('NotoNaskhArabic');
  for (final w in ['Regular', 'Bold']) {
    arabic.addFont(Future.value(ByteData.sublistView(File('assets/fonts/NotoNaskhArabic-$w.ttf').readAsBytesSync())));
  }
  await arabic.load();
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
    await tester.enterText(find.widgetWithText(TextFormField, 'Odoo address'), 'https://gulffoods.example.com');
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
    expect(find.text('AED 560.00 / pc'), findsOneWidget, reason: "Maggi at the customer's price list price");
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
    expect(find.text('AED 1,360.00'), findsOneWidget);
    expect(find.text('AED 244.80'), findsOneWidget);
    await tester.tap(find.textContaining('Place order'));
    await screen('order');
    expect(find.text('Waiting to sync'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Collect the overdue invoice by bank transfer.
    await tester.tap(find.text('Collect payment'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('INV/2026/00042'));
    await tester.tap(find.text('Bank transfer'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Bank transfer reference (optional)'), '430912345678');
    expect(find.text('Cheque'), findsOneWidget, reason: 'payment methods come from Odoo');
    await screen('payment');
    expect(find.text('Record AED 1,200.00 by Bank transfer'), findsOneWidget);
    await tester.tap(find.text('Record AED 1,200.00 by Bank transfer'));
    await tester.pumpAndSettle();
    expect(find.text('IN THIS VISIT'), findsOneWidget);
    expect(find.text('Bank transfer payment'), findsOneWidget);
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
    expect(paymentVals['payment_method_line_id'], 32, reason: 'the bank transfer method set up in Odoo');
    expect(paymentVals['invoice_ids'], [77]);
    expect(paymentVals['beatpro_reference'], '430912345678');

    // Close the day.
    container.read(routerProvider).push('/day-close');
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Distance travelled'), '23');
    await screen('day-close');
    await tester.tap(find.text('Close day and hand over'));
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
    await tester.enterText(find.widgetWithText(TextFormField, 'Odoo address'), 'https://gulffoods.example.com');
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

    await tester.enterText(find.widgetWithText(TextFormField, 'Odoo address'), 'https://gulffoods.example.com');
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
    expect(find.text('36 items'), findsOneWidget);
    await screen('15-van-load');
    await tester.tap(find.text('Send load request · 36 items'));
    await tester.pumpAndSettle();
    final load = odoo.uploaded['beatpro.van.transfer.load']!.single;
    expect((load['line_ids'] as List).length, 3);
    expect((await repo.vanStock()).loadWaiting, isTrue);

    // The storekeeper loads the van; the next sync brings the stock.
    odoo.storekeeperLoads();
    await container.read(syncControllerProvider.notifier).run();
    router.push('/van');
    await tester.pumpAndSettle();
    expect(find.text('36 items'), findsNWidgets(2), reason: 'in the van now, and loaded');
    expect(find.text('AED 15,920.00 at sale price'), findsOneWidget);
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
    await tester.tap(find.text('Take back 5 items · AED 1,680.00 credit'));
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
    expect(find.text('1 pc short: Parle-G Biscuits (Box of 24)'), findsOneWidget);
    expect(find.text('2 items'), findsOneWidget, reason: 'damaged returns go to the damaged area');
    await tester.tap(find.text('Send unload · 32 items'));
    await tester.pumpAndSettle();
    expect(odoo.uploaded['beatpro.van.transfer.unload'], isNull, reason: 'a shortage needs a note');
    await tester.enterText(find.byType(TextField).last, 'One box torn, given to the shop as a free sample.');
    await tester.pumpAndSettle();
    await screen('19-van-unload');
    await tester.tap(find.text('Send unload · 32 items'));
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
    await tester.enterText(find.widgetWithText(TextFormField, 'Odoo address'), 'https://gulffoods.example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Database (optional)'), 'gulffoods');
    await tester.enterText(find.widgetWithText(TextFormField, 'Email or username'), 'ravi@beatpro.test');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'ravi123');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(odoo.signIns.last['header_db'], 'gulffoods', reason: 'Odoo picks the database from this header');
    expect(find.text('Van Sales Dashboard', skipOffstage: false), findsOneWidget, reason: 'a card on My Day');
    container.read(routerProvider).push('/dashboard');
    await tester.pumpAndSettle();
    expect(find.text('AED 75,484.00'), findsWidgets);
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
    await tester.enterText(find.widgetWithText(TextFormField, 'Odoo address'), 'https://gulffoods.example.com');
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
    expect(find.text('Send load request · 38 items'), findsOneWidget, reason: '36 suggested + 2 scanned');
    await tester.tap(find.text('Send load request · 38 items'));
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
    expect(scanner.feedback.last.message, 'Added Parle-G Biscuits (Box of 24) · 3 pc in the order');
    await tester.enterText(find.widgetWithText(TextField, 'Search or scan products'), '8904043901015');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Added Tata Salt 1kg (Bag of 10) · 1 pc in the order'), findsOneWidget);
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
    expect(find.text('Take back 2 items · AED 960.00 credit'), findsOneWidget);
    await tester.tap(find.text('Take back 2 items · AED 960.00 credit'));
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
    expect(scanner.feedback.last.message, 'Maggi Noodles (Case of 48) · counted 2 pc of 2 pc');
    scanner.queue.add('8901030704116');
    await tester.tap(find.byTooltip('Scan barcodes'));
    await tester.pumpAndSettle();
    expect(scanner.feedback.last.ok, isFalse, reason: "Surf Excel isn't in the van");

    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets('a van delivery is invoiced and printed at the shop', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final odoo = FakeOdoo()..withVan = true;
    final printer = FakePrinter();
    final db = await LocalDb.open(factory: databaseFactoryFfiNoIsolate, path: inMemoryDatabasePath);
    final container = ProviderContainer(overrides: [
      localDbProvider.overrideWithValue(db),
      credentialStoreProvider.overrideWithValue(MemoryCredentialStore()),
      locationProvider.overrideWithValue(const FixedLocationService(null)),
      httpClientProvider.overrideWithValue(odoo.client),
      printerServiceProvider.overrideWithValue(printer),
    ]);
    addTearDown(container.dispose);
    const appKey = Key('app');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const RepaintBoundary(key: appKey, child: BeatproApp()),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Odoo address'), 'https://gulffoods.example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Email or username'), 'ravi@beatpro.test');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'ravi123');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    final router = container.read(routerProvider);
    final repo = container.read(repositoryProvider);
    final year = DateTime.now().year;

    // Load the van.
    await repo.requestLoad({for (final p in await repo.db.products()) p: 10});
    await container.read(syncControllerProvider.notifier).run();
    odoo.storekeeperLoads();
    await container.read(syncControllerProvider.notifier).run();

    // Patel Kirana has a TRN: a full tax invoice, numbered from the van's series without signal.
    odoo.offline = true;
    final visit = await repo.startVisit('srv:9');
    router.push('/order/new?customer=srv%3A9&visit=${visit.uuid}');
    await tester.pumpAndSettle();
    Finder inTile(String product, Finder f) => find.descendant(of: find.widgetWithText(ListTile, product), matching: f);
    await tester.tap(inTile('Parle-G Biscuits (Box of 24)', find.widgetWithText(OutlinedButton, 'Add')));
    await tester.pump();
    await tester.tap(inTile('Parle-G Biscuits (Box of 24)', find.byTooltip('More')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Review'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Deliver now ·'));
    await tester.pumpAndSettle();

    final number = 'VAN1/$year/00147';
    expect(find.text(number), findsWidgets);
    expect(find.text('TAX INVOICE'), findsOneWidget);
    expect(find.text('TRN 100987654300003'), findsOneWidget);
    expect(find.text('TRN 100234567800003'), findsOneWidget);
    expect(find.text('VAT 18%'), findsOneWidget);
    // 2 × 240 = 480 + 18% = 566.40.
    expect(find.text('566.40'), findsWidgets);
    expect(find.text('Not synced yet'), findsOneWidget);
    if (Platform.environment['BEATPRO_SCREENSHOTS'] != null) {
      await _loadImages(tester);
      await expectLater(find.byKey(appKey), matchesGoldenFile('../docs/screenshots/22-invoice.png'));
    }

    // First print: choose the printer, then the slip goes to it.
    await tester.scrollUntilVisible(find.text('Print'), 300, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Print'));
    await tester.pumpAndSettle();
    expect(find.text('Printer'), findsOneWidget);
    await tester.tap(find.text('BT-58 Thermal'));
    await tester.pumpAndSettle();
    if (Platform.environment['BEATPRO_SCREENSHOTS'] != null) {
      await expectLater(find.byKey(appKey), matchesGoldenFile('../docs/screenshots/23-printer.png'));
    }
    // Done: back on the invoice, it prints straight away.
    await tester.runAsync(() async {
      await tester.tap(find.text('Done'));
      for (var i = 0; i < 20 && printer.jobs.isEmpty; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Printed on BT-58 Thermal'), findsOneWidget);
    expect(printer.jobs, hasLength(1));
    final job = printer.jobs.single;
    expect(job.sublist(0, 2), [0x1B, 0x40]);
    expect(job.sublist(2, 6), [0x1D, 0x76, 0x30, 0x00], reason: 'the slip prints as an image');
    expect(job[6] + job[7] * 256, 72, reason: '80 mm paper: 576 dots = 72 bytes a row');

    // A second van delivery offline takes the next number.
    final second = await repo.placeOrder(
      customerKey: 'srv:9',
      visitUuid: visit.uuid,
      delivery: DeliveryMode.van,
      lines: [CartLine(product: (await repo.db.products()).first, unitPrice: 240, qty: 1)],
    );
    expect((second.data['invoice'] as Map)['name'], 'VAN1/$year/00148');

    // Back online: Odoo keeps the first number; the second was used meanwhile and gets another.
    odoo.offline = false;
    await repo.checkOut(visit.uuid, result: VisitResult.order);
    await container.read(syncControllerProvider.notifier).run();
    expect(odoo.uploaded['sale.order']!.first['beatpro_van_invoice_name'], number);
    odoo.renumberInvoices = true;
    await repo.db.saveRecord((await repo.db.record(second.uuid))!.copyWith(state: SyncState.pending));
    await container.read(syncControllerProvider.notifier).run();
    final renumbered = (await repo.invoiceFor(second.uuid))!;
    expect(renumbered.name, 'VAN1/2026/00999');
    expect(renumbered.renumberedFrom, 'VAN1/$year/00148');

    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets('cases, a free-goods scheme and a credit warning on a van order', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final odoo = FakeOdoo()
      ..withVan = true
      ..withSchemes = true;
    final db = await LocalDb.open(factory: databaseFactoryFfiNoIsolate, path: inMemoryDatabasePath);
    final container = ProviderContainer(overrides: [
      localDbProvider.overrideWithValue(db),
      credentialStoreProvider.overrideWithValue(MemoryCredentialStore()),
      locationProvider.overrideWithValue(const FixedLocationService(null)),
      httpClientProvider.overrideWithValue(odoo.client),
      printerServiceProvider.overrideWithValue(FakePrinter()),
    ]);
    addTearDown(container.dispose);
    const appKey = Key('app');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const RepaintBoundary(key: appKey, child: BeatproApp()),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Odoo address'), 'https://gulffoods.example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Email or username'), 'ravi@beatpro.test');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'ravi123');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    final router = container.read(routerProvider);
    final repo = container.read(repositoryProvider);
    final products = {for (final p in await repo.db.products()) p.id: p};
    expect(products[1]!.caseUnit?.name, 'Case of 24');
    await repo.requestLoad({for (final p in products.values) p: p.id == 1 ? 300 : 10});
    await container.read(syncControllerProvider.notifier).run();
    odoo.storekeeperLoads();
    await container.read(syncControllerProvider.notifier).run();

    final visit = await repo.startVisit('srv:9');
    router.push('/order/new?customer=srv%3A9&visit=${visit.uuid}');
    await tester.pumpAndSettle();
    // Patel Kirana owes more than its limit: a warning, not a block.
    expect(find.text('Over the credit limit'), findsOneWidget);
    expect(find.textContaining('INV/2026/00042 is 25 days overdue'), findsOneWidget);
    expect(find.text('1 scheme running · they apply by themselves'), findsOneWidget);
    Finder inTile(String product, Finder f) => find.descendant(of: find.widgetWithText(ListTile, product), matching: f);
    const parle = 'Parle-G Biscuits (Box of 24)';
    // Parle-G starts in cases: a case of 24 at AED 10 a piece.
    expect(inTile(parle, find.text('AED 240.00 / cs')), findsOneWidget);
    expect(inTile(parle, find.text('12 cs + 12 pc in van')), findsOneWidget);
    expect(inTile(parle, find.text('Buy 10 Case of 24, get 1 free')), findsOneWidget);
    await tester.tap(inTile(parle, find.widgetWithText(OutlinedButton, 'Add')));
    await tester.pump();
    expect(inTile(parle, find.text('9 cs more: 1 free')), findsOneWidget);
    for (var i = 0; i < 9; i++) {
      await tester.tap(inTile(parle, find.byTooltip('More')));
      await tester.pump();
    }
    expect(inTile(parle, find.text('1 cs free earned')), findsOneWidget);
    // Maggi by the piece: 10 or more at the quantity price.
    const maggi = 'Maggi Noodles (Case of 48)';
    expect(inTile(maggi, find.text('AED 540.00 / pc from 10 pc')), findsOneWidget);
    await tester.tap(inTile(maggi, find.widgetWithText(OutlinedButton, 'Add')));
    await tester.pump();
    await tester.pumpAndSettle();
    if (Platform.environment['BEATPRO_SCREENSHOTS'] != null) {
      await _loadImages(tester);
      await expectLater(find.byKey(appKey), matchesGoldenFile('../docs/screenshots/24-schemes-order.png'));
    }

    await tester.tap(find.textContaining('Review'));
    await tester.pumpAndSettle();
    expect(find.text('$parle · FREE'), findsOneWidget);
    expect(find.text('1 cs · Parle-G: buy 10 cases, get 1 free'), findsOneWidget);
    expect(find.text('The shop saves AED 240.00'), findsOneWidget);
    expect(find.text('1 cs Parle-G Biscuits (Box of 24) free'), findsOneWidget);
    // 10 cases at 240 + 1 Maggi at 560, plus 18%: the free case costs nothing.
    expect(find.text('AED 3,492.80'), findsWidgets);
    if (Platform.environment['BEATPRO_SCREENSHOTS'] != null) {
      await expectLater(find.byKey(appKey), matchesGoldenFile('../docs/screenshots/25-schemes-summary.png'));
    }
    await tester.tap(find.textContaining('Deliver now ·'));
    await tester.pumpAndSettle();

    // The invoice printed at the shop: the free case and what the shop saved.
    expect(find.text('$parle · FREE'), findsOneWidget);
    expect(find.text('FREE · Parle-G: buy 10 cases, get 1 free'), findsOneWidget);
    expect(find.text('10 cs x 240.00 · 2400.00'), findsOneWidget);
    expect(find.text('You saved AED'), findsOneWidget);
    if (Platform.environment['BEATPRO_SCREENSHOTS'] != null) {
      await expectLater(find.byKey(appKey), matchesGoldenFile('../docs/screenshots/26-schemes-invoice.png'));
    }
    // 11 cases left the van, free one included: 300 - 264 pieces.
    expect((await repo.vanStock()).leftOf(1), 36);

    // Odoo gets the cases bought; it adds the free case itself, from the same scheme.
    await repo.checkOut(visit.uuid, result: VisitResult.order);
    await container.read(syncControllerProvider.notifier).run();
    final lines = [for (final l in odoo.uploaded['sale.order']!.last['order_line'] as List) (l as List)[2] as Map];
    expect(lines.firstWhere((l) => l['product_id'] == 1), {'product_id': 1, 'product_uom_qty': 10.0, 'product_uom_id': 7, 'discount': 0.0});
    expect(lines, hasLength(2));

    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets('a payment settles the invoice printed at the shop, using a credit note', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final odoo = FakeOdoo()..withVan = true;
    final db = await LocalDb.open(factory: databaseFactoryFfiNoIsolate, path: inMemoryDatabasePath);
    final container = ProviderContainer(overrides: [
      localDbProvider.overrideWithValue(db),
      credentialStoreProvider.overrideWithValue(MemoryCredentialStore()),
      locationProvider.overrideWithValue(const FixedLocationService(null)),
      httpClientProvider.overrideWithValue(odoo.client),
      printerServiceProvider.overrideWithValue(FakePrinter()),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const BeatproApp()));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Odoo address'), 'https://gulffoods.example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Email or username'), 'ravi@beatpro.test');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'ravi123');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    final router = container.read(routerProvider);
    final repo = container.read(repositoryProvider);
    await repo.requestLoad({for (final p in await repo.db.products()) p: 10});
    await container.read(syncControllerProvider.notifier).run();
    odoo.storekeeperLoads();
    await container.read(syncControllerProvider.notifier).run();

    // Offline at the shop: goods taken back, then a van delivery with its invoice.
    odoo.offline = true;
    final visit = await repo.startVisit('srv:9');
    final biscuits = (await repo.db.products()).first;
    final taken = await repo.takeBack(customerKey: 'srv:9', visitUuid: visit.uuid, lines: [
      ReturnLine(productId: biscuits.id, name: biscuits.name, priceUnit: 240, qty: 1, reason: ReturnReason.defaults.first),
    ]);
    final order = await repo.placeOrder(
      customerKey: 'srv:9',
      visitUuid: visit.uuid,
      delivery: DeliveryMode.van,
      lines: [CartLine(product: biscuits, unitPrice: 240, qty: 2)],
    );
    // The Sync screen lists everything waiting, goods taken back and van loads included.
    await repo.requestLoad({biscuits: 24});
    router.push('/sync');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Goods taken back'), findsOneWidget);
    expect(find.text('Van load'), findsWidgets);
    router.pop();
    await tester.pumpAndSettle();

    router.push('/invoice/${order.uuid}');
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Collect payment ·'));
    await tester.pumpAndSettle();

    // The invoice just printed is ticked: 2 × 240 + 18% VAT.
    final invoiceTile = find.widgetWithText(CheckboxListTile, (order.data['invoice'] as Map)['name'] as String);
    expect(tester.widget<CheckboxListTile>(invoiceTile).value, isTrue);
    expect(find.text('Printed at the shop · not synced yet'), findsOneWidget);
    expect(find.widgetWithText(TextField, '566.40'), findsOneWidget);
    // The shop uses its credit for the goods taken back (240 + 18%); it pays the rest.
    await tester.tap(find.textContaining('Credit note · use it'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '283.20'), findsOneWidget);
    await tester.tap(find.textContaining('Record '));
    await tester.pumpAndSettle();
    expect(await repo.openItemsFor('srv:9'), isEmpty, reason: 'invoice and credit used up on the phone');

    // In Odoo the payment names the order and the return, so it settles that invoice.
    odoo.offline = false;
    await repo.checkOut(visit.uuid, result: VisitResult.order);
    await container.read(syncControllerProvider.notifier).run();
    final sent = odoo.uploaded['account.payment']!.single;
    expect(sent['amount'], 283.2);
    expect(sent['order_uuids'], [order.uuid]);
    expect(sent['return_uuids'], [taken.uuid]);

    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets('target and incentive, shelf photos, shop survey and location for the live map', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final odoo = FakeOdoo()..withGrowth = true;
    final camera = FakePhotoService();
    final photoDir = (await tester.runAsync(() => Directory.systemTemp.createTemp('beatpro_photos')))!;
    addTearDown(() => tester.runAsync(() => photoDir.delete(recursive: true)));
    final db = await LocalDb.open(factory: databaseFactoryFfiNoIsolate, path: inMemoryDatabasePath);
    final container = ProviderContainer(overrides: [
      localDbProvider.overrideWithValue(db),
      credentialStoreProvider.overrideWithValue(MemoryCredentialStore()),
      locationProvider.overrideWithValue(const FixedLocationService(GeoPoint(25.2399, 55.3046))),
      httpClientProvider.overrideWithValue(odoo.client),
      photoServiceProvider.overrideWithValue(camera),
      photoDirProvider.overrideWith((ref) async => photoDir),
    ]);
    addTearDown(container.dispose);
    const appKey = Key('app');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const RepaintBoundary(key: appKey, child: BeatproApp()),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Odoo address'), 'https://gulffoods.example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Email or username'), 'ravi@beatpro.test');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'ravi123');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    final router = container.read(routerProvider);
    final repo = container.read(repositoryProvider);

    // Paid on salary + incentive: the month's target on Home.
    expect(find.text('My target · November'), findsOneWidget);
    expect(find.text('71%'), findsOneWidget);
    expect(find.textContaining('Your location is shared with your supervisor'), findsOneWidget);
    if (Platform.environment['BEATPRO_SCREENSHOTS'] != null) {
      await _loadImages(tester);
      await expectLater(find.byKey(appKey), matchesGoldenFile('../docs/screenshots/27-target-home.png'));
    }
    await tester.ensureVisible(find.text('My target · November'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My target · November'));
    await tester.pumpAndSettle();
    expect(find.text('From AED 10,000.00'), findsOneWidget);
    expect(find.text('2% on each part'), findsOneWidget);
    expect(find.text('132 / 200 cs'), findsOneWidget);
    if (Platform.environment['BEATPRO_SCREENSHOTS'] != null) {
      await expectLater(find.byKey(appKey), matchesGoldenFile('../docs/screenshots/28-target.png'));
    }
    router.pop();
    await tester.pumpAndSettle();

    // At Patel Kirana: the monthly shelf check is due, with two shelf photos.
    final visit = await repo.startVisit('srv:9', at: const GeoPoint(25.2399, 55.3046));
    router.push('/visit/${visit.uuid}');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Shelf photos 0/2'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Shelf photos 0/2'));
    await tester.pumpAndSettle();
    expect(find.text('Needed at this shop: 2 of main shelf'), findsOneWidget);
    for (var i = 0; i < 2; i++) {
      await tester.runAsync(() async {
        await tester.tap(find.text('Take photo of main shelf'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
    }
    expect(find.text('2 of 2 needed taken'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    if (Platform.environment['BEATPRO_SCREENSHOTS'] != null) {
      await expectLater(find.byKey(appKey), matchesGoldenFile('../docs/screenshots/29-shelf-photos.png'));
    }
    router.pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Monthly shelf check'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save answers'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Answer: Is our display stand in place?'), findsOneWidget, reason: 'required questions');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Yes'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '6');
    await tester.tap(find.text('Eye level'));
    await tester.pump();
    if (Platform.environment['BEATPRO_SCREENSHOTS'] != null) {
      await expectLater(find.byKey(appKey), matchesGoldenFile('../docs/screenshots/30-survey.png'));
    }
    await tester.tap(find.text('Save answers'));
    await tester.pumpAndSettle();
    expect(find.text('Answers saved. They are sent with the visit.'), findsOneWidget);

    // Positions wait on the phone while working; check-in added one, the timer adds more.
    final tracker = container.read(locationTrackerProvider);
    expect(await tester.runAsync(tracker.tick), isTrue);
    expect((await repo.locationQueue()).length, 2);

    // Sync: photos and answers go with the visit, then the positions.
    await repo.checkOut(visit.uuid, result: VisitResult.noOrder, noOrderReason: 'enough_stock');
    await tester.runAsync(() => container.read(syncControllerProvider.notifier).run());
    await tester.pumpAndSettle();
    final extras = odoo.uploaded['beatpro.visit.extras']!;
    final photos = [for (final e in extras) ...(e['photos'] as List).cast<Map>()];
    expect(photos, hasLength(2));
    expect(photos.first['tag'], 'Main shelf');
    expect(base64Decode(photos.first['image'] as String).sublist(0, 2), [0xFF, 0xD8]);
    final answers = [for (final e in extras) ...(e['answers'] as List).cast<Map>()];
    expect({for (final a in answers) a['question_id']: a['value']}, {41: true, 42: '6', 43: 'Eye level'});
    expect(odoo.uploaded['beatpro.location'], hasLength(2));
    expect(await repo.locationQueue(), isEmpty);
    expect(photoDir.listSync(), isEmpty, reason: 'photos leave the phone once Odoo has them');

    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets('expenses come off the cash handed in at day end', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final odoo = FakeOdoo();
    final camera = FakePhotoService();
    final photoDir = (await tester.runAsync(() => Directory.systemTemp.createTemp('beatpro_receipts')))!;
    addTearDown(() => tester.runAsync(() => photoDir.delete(recursive: true)));
    final db = await LocalDb.open(factory: databaseFactoryFfiNoIsolate, path: inMemoryDatabasePath);
    final container = ProviderContainer(overrides: [
      localDbProvider.overrideWithValue(db),
      credentialStoreProvider.overrideWithValue(MemoryCredentialStore()),
      locationProvider.overrideWithValue(const FixedLocationService(null)),
      httpClientProvider.overrideWithValue(odoo.client),
      photoServiceProvider.overrideWithValue(camera),
      photoDirProvider.overrideWith((ref) async => photoDir),
    ]);
    addTearDown(container.dispose);
    const appKey = Key('app');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const RepaintBoundary(key: appKey, child: BeatproApp()),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Odoo address'), 'https://gulffoods.example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Email or username'), 'ravi@beatpro.test');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'ravi123');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    final router = container.read(routerProvider);
    final repo = container.read(repositoryProvider);

    // AED 500 collected in cash at a shop.
    odoo.offline = true;
    await repo.collectPayment(
      customerKey: 'srv:8',
      amount: 500,
      method: (await repo.appContext())!.paymentMethods.firstWhere((m) => m.kind == 'cash'),
    );

    // Fuel paid from that cash, with a receipt photo.
    router.push('/expense/new');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fuel'));
    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '120');
    await tester.enterText(find.widgetWithText(TextField, 'Where (optional)'), 'ENOC Al Quoz');
    await tester.tap(find.text('Receipt photo (optional)'));
    await tester.pumpAndSettle();
    expect(find.text('Receipt photo taken · retake'), findsOneWidget);
    if (Platform.environment['BEATPRO_SCREENSHOTS'] != null) {
      await _loadImages(tester);
      await expectLater(find.byKey(appKey), matchesGoldenFile('../docs/screenshots/31-expense.png'));
    }
    await tester.runAsync(() async {
      await tester.tap(find.text('Save expense'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    // Parking paid with own money: not taken off the cash.
    await repo.addExpense(categoryId: 2, categoryName: 'Parking', amount: 8, paidFrom: 'own');

    router.push('/day-close');
    await tester.pumpAndSettle();
    expect(find.text('Hand in to the cashier'), findsOneWidget);
    expect(find.text('after AED 120.00 expenses'), findsOneWidget);
    expect(find.text('AED 380.00'), findsWidgets, reason: '500 collected less 120 fuel');
    if (Platform.environment['BEATPRO_SCREENSHOTS'] != null) {
      await expectLater(find.byKey(appKey), matchesGoldenFile('../docs/screenshots/32-day-close-hand-over.png'));
    }
    router.pop();
    await tester.pumpAndSettle();

    // Online again: the expenses reach Odoo, with the receipt.
    odoo.offline = false;
    await tester.runAsync(() => container.read(syncControllerProvider.notifier).run());
    await tester.pumpAndSettle();
    final sent = odoo.uploaded['beatpro.expense']!;
    expect(sent, hasLength(2));
    final fuel = sent.firstWhere((e) => e['paid_from'] == 'cash');
    expect(fuel['amount'], 120.0);
    expect(fuel['note'], 'ENOC Al Quoz');
    expect(base64Decode(fuel['receipt'] as String).sublist(0, 2), [0xFF, 0xD8]);
    expect(sent.firstWhere((e) => e['paid_from'] == 'own').containsKey('receipt'), isFalse, reason: 'the receipt is optional');
    expect(photoDir.listSync(), isEmpty, reason: 'the receipt leaves the phone once Odoo has it');

    router.push('/expenses');
    await tester.pumpAndSettle();
    expect(find.text('Waiting'), findsWidgets);
    if (Platform.environment['BEATPRO_SCREENSHOTS'] != null) {
      await expectLater(find.byKey(appKey), matchesGoldenFile('../docs/screenshots/33-my-expenses.png'));
    }

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
    await tester.enterText(find.widgetWithText(TextFormField, 'Odoo address'), 'https://gulffoods.example.com');
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
