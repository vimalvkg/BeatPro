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
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_odoo.dart';

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
      await expectLater(
        find.byKey(appKey),
        matchesGoldenFile('../docs/screenshots/${shot.toString().padLeft(2, '0')}-$name.png'),
      );
    }

    // Sign in.
    expect(find.text("Connect to your company's Odoo"), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Odoo address'), 'https://mumbai.example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'API key'), 'k' * 40);
    await screen('sign-in');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    // Home.
    expect(find.text('Hello, Ravi'), findsOneWidget);
    expect(find.text('0 of 4 visits done'), findsOneWidget);
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
    expect(find.textContaining('Checked in at'), findsOneWidget);

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
    await screen('payment');
    await tester.tap(find.text('Record payment'));
    await tester.pumpAndSettle();
    expect(find.text('PAYMENTS IN THIS VISIT'), findsOneWidget);
    expect(find.text('UPI'), findsOneWidget);
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
    expect(paymentVals['beatpro_method'], 'upi');
    expect(paymentVals['invoice_ids'], [77]);
    expect(paymentVals['beatpro_upi_reference'], '430912345678');

    // Close the day.
    container.read(routerProvider).push('/day-close');
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Distance travelled'), '23');
    await screen('day-close');
    await tester.tap(find.widgetWithText(FilledButton, 'Close day'));
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
    await tester.enterText(find.widgetWithText(TextFormField, 'API key'), 'k' * 40);
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

    odoo.offline = false;
    final second = await container.read(syncControllerProvider.notifier).run();
    expect(second!.ok, isTrue);
    expect(await repo.pendingCount(), 0);
    expect(odoo.uploaded['beatpro.visit']!.single['no_order_reason'], 'enough_stock');

    await tester.pumpWidget(const SizedBox());
    await db.close();
  });
}
