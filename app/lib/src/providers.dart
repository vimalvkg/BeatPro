import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'core/local_db.dart';
import 'core/models.dart';
import 'core/odoo_client.dart';
import 'core/repository.dart';
import 'core/services.dart';
import 'core/sync_service.dart';

/// Overridden in main() and in tests.
final localDbProvider = Provider<LocalDb>((ref) => throw UnimplementedError('localDbProvider must be overridden'));
final credentialStoreProvider = Provider<CredentialStore>((ref) => const SecureCredentialStore());
final locationProvider = Provider<LocationService>((ref) => const GpsLocationService());

/// The HTTP client used to reach Odoo; tests swap in a fake server.
final httpClientProvider = Provider<http.Client?>((ref) => null);

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

final ordersProvider = FutureProvider<List<LocalRecord>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).orders();
});

final recordsProvider = FutureProvider<List<LocalRecord>>((ref) async {
  ref.watch(dataVersionProvider);
  final db = ref.watch(localDbProvider);
  return (await db.records()).reversed.toList();
});

final todayCloseProvider = FutureProvider<LocalRecord?>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(repositoryProvider).todayClose();
});
