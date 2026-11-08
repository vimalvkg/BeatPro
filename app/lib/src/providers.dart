import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'core/local_db.dart';
import 'core/location_tracker.dart';
import 'core/growth.dart';
import 'core/models.dart';
import 'core/odoo_client.dart';
import 'core/printer.dart';
import 'core/repository.dart';
import 'core/services.dart';
import 'core/sync_service.dart';

/// Overridden in main() and in tests.
final localDbProvider = Provider<LocalDb>((ref) => throw UnimplementedError('localDbProvider must be overridden'));
final credentialStoreProvider = Provider<CredentialStore>((ref) => const SecureCredentialStore());
final locationProvider = Provider<LocationService>((ref) => const GpsLocationService());

/// The HTTP client used to reach Odoo; tests swap in a fake server.
final httpClientProvider = Provider<http.Client?>((ref) => null);

/// The Bluetooth thermal printer; tests swap in a fake.
final printerServiceProvider = Provider<PrinterService>((ref) => const BluetoothPrinterService());

final repositoryProvider = Provider<Repository>((ref) => Repository(ref.watch(localDbProvider)));

/// The signed-in Odoo connection, or null before sign-in.
class SessionNotifier extends Notifier<OdooCredentials?> {
  @override
  OdooCredentials? build() => null;

  Future<void> restore() async {
    state = await ref.read(credentialStoreProvider).read();
  }

  /// Checks the details against Odoo, downloads the rep's data and remembers them.
  Future<void> signIn(OdooCredentials credentials) async {
    final client = OdooClient(credentials, httpClient: ref.read(httpClientProvider));
    final context = await client.call('res.users', 'beatpro_app_context') as Map<String, dynamic>;
    if (context['is_rep'] != true) {
      throw OdooException(
        'This user is not a BeatPro rep. Ask your administrator to add you to the BeatPro Field Sales group.',
      );
    }
    final db = ref.read(localDbProvider);
    final previousUser = (await ref.read(repositoryProvider).appContext())?.userId;
    if (previousUser != null && previousUser != context['user_id']) {
      await db.clear();
    }
    await SyncService(db, client).download();
    await ref.read(credentialStoreProvider).write(credentials);
    state = credentials;
  }

  /// Signs in with the user's Odoo login and password: Odoo returns an API key
  /// for this phone, which is kept instead of the password.
  Future<void> signInWithPassword({
    required String url,
    required String database,
    required String login,
    required String password,
  }) async {
    final credentials = await OdooCredentials.signInWithPassword(
      url: url,
      database: database,
      login: login,
      password: password,
      device: await _deviceName(),
      httpClient: ref.read(httpClientProvider),
    );
    await signIn(credentials);
  }

  /// "Android · a1b2c3": tells this phone's key apart in the user's Odoo profile.
  Future<String> _deviceName() async {
    final db = ref.read(localDbProvider);
    var id = await db.getValue('install_id');
    if (id == null) {
      id = const Uuid().v4().substring(0, 6);
      await db.setValue('install_id', id);
    }
    final os = Platform.isAndroid ? 'Android' : Platform.isIOS ? 'iPhone' : Platform.operatingSystem;
    return '$os · $id';
  }

  Future<void> signOut() async {
    await ref.read(credentialStoreProvider).clear();
    await ref.read(localDbProvider).clear();
    state = null;
  }
}

final sessionProvider = NotifierProvider<SessionNotifier, OdooCredentials?>(SessionNotifier.new);

final odooClientProvider = Provider<OdooClient?>((ref) {
  final credentials = ref.watch(sessionProvider);
  if (credentials == null) return null;
  final client = OdooClient(credentials, httpClient: ref.watch(httpClientProvider));
  ref.onDispose(client.close);
  return client;
});

final syncServiceProvider = Provider<SyncService?>((ref) {
  final client = ref.watch(odooClientProvider);
  return client == null ? null : SyncService(ref.watch(localDbProvider), client);
});

/// Bumped after anything changes the phone's data, so screens reload.
class DataVersion extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final dataVersionProvider = NotifierProvider<DataVersion, int>(DataVersion.new);

/// Runs a sync and remembers the last report for the Sync screen.
class SyncController extends Notifier<AsyncValue<SyncReport?>> {
  @override
  AsyncValue<SyncReport?> build() => const AsyncData(null);

  Future<SyncReport?> run() async {
    final service = ref.read(syncServiceProvider);
    if (service == null || state.isLoading) return null;
    state = const AsyncLoading();
    try {
      final report = await service.sync();
      state = AsyncData(report);
      return report;
    } on OdooException catch (e, st) {
      state = AsyncError(e, st);
      return null;
    } finally {
      ref.read(dataVersionProvider.notifier).bump();
    }
  }
}

final syncControllerProvider = NotifierProvider<SyncController, AsyncValue<SyncReport?>>(SyncController.new);

// -- Data the screens show -------------------------------------------------

/// The camera, for shelf photos. Tests use a fake.
final photoServiceProvider = Provider<PhotoService>((ref) => const CameraPhotoService());

/// Where shelf photos wait on the phone until they sync.
final photoDirProvider = FutureProvider<Directory>((ref) async =>
    Directory('${(await getApplicationSupportDirectory()).path}/photos'));

/// The Live Map's position timer; main() starts it, tests don't.
final locationTrackerProvider = Provider<LocationTracker>((ref) {
  final tracker = LocationTracker(
    ref.watch(repositoryProvider),
    ref.watch(locationProvider),
    upload: () async => ref.read(syncServiceProvider)?.uploadLocations(),
  );
  ref.onDispose(tracker.stop);
  return tracker;
});

final myExpensesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).myExpenses();
});

final cashSpentTodayProvider = FutureProvider<double>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).cashSpentToday();
});

final myTargetProvider = FutureProvider<MyTarget?>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).myTarget();
});

final surveysForProvider = FutureProvider.family<List<Survey>, String>((ref, customerKey) {
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).surveysFor(customerKey);
});

final photosForProvider = FutureProvider.family<List<LocalRecord>, String>((ref, visitUuid) {
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).photosFor(visitUuid);
});

final appContextProvider = FutureProvider<AppContext?>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).appContext();
});

final moneyProvider = Provider<Money>((ref) => Money(ref.watch(appContextProvider).value));

final todayPlanProvider = FutureProvider<List<StopView>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).todayPlan();
});

final activeVisitProvider = FutureProvider<LocalRecord?>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).activeVisit();
});

final daySummaryProvider = FutureProvider<DaySummary>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).todaySummary();
});

final pendingCountProvider = FutureProvider<int>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).pendingCount();
});

final lastSyncProvider = FutureProvider<DateTime?>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).lastSync();
});

final customerSearchProvider = FutureProvider.family<List<Customer>, String>((ref, search) {
  ref.watch(dataVersionProvider);
  return ref.watch(localDbProvider).customers(search: search);
});

final customerProvider = FutureProvider.family<Customer?, String>((ref, key) {
  ref.watch(dataVersionProvider);
  return ref.watch(localDbProvider).customer(key);
});

final invoicesProvider = FutureProvider.family<List<OpenInvoice>, String>((ref, customerKey) {
  ref.watch(dataVersionProvider);
  return ref.watch(localDbProvider).invoices(customerKey: customerKey);
});

/// Invoices and credit notes a payment can settle, including ones made on the phone.
final openItemsProvider = FutureProvider.family<List<OpenInvoice>, String>((ref, customerKey) {
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).openItemsFor(customerKey);
});

final ordersProvider = FutureProvider<List<LocalRecord>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).orders();
});

final recordsProvider = FutureProvider<List<LocalRecord>>((ref) async {
  ref.watch(dataVersionProvider);
  final db = ref.watch(localDbProvider);
  return (await db.records()).reversed.toList();
});

/// Products by id, for showing quantities as cases and pieces.
final productsByIdProvider = FutureProvider<Map<int, Product>>((ref) async {
  ref.watch(dataVersionProvider);
  return {for (final p in await ref.watch(localDbProvider).products()) p.id: p};
});

final vanStockProvider = FutureProvider<VanStockView>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).vanStock();
});

final todayCloseProvider = FutureProvider<LocalRecord?>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).todayClose();
});
