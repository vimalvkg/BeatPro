import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers.dart';
import 'screens/add_customer_screen.dart';
import 'screens/customer_detail_screen.dart';
import 'screens/customers_screen.dart';
import 'screens/day_close_screen.dart';
import 'screens/home_screen.dart';
import 'screens/more_screen.dart';
import 'screens/order_screen.dart';
import 'screens/orders_screen.dart';
import 'screens/payment_screen.dart';
import 'screens/route_screen.dart';
import 'screens/sign_in_screen.dart';
import 'screens/sync_screen.dart';
import 'screens/visit_screen.dart';
import 'theme.dart';

/// Lets the router react to sign-in and sign-out.
class _SessionListenable extends ChangeNotifier {
  void notify() => notifyListeners();
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _SessionListenable();
  ref.listen(sessionProvider, (_, _) => refresh.notify());
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/home',
    refreshListenable: refresh,
    redirect: (context, state) {
      final signedIn = ref.read(sessionProvider) != null;
      final atSignIn = state.matchedLocation == '/sign-in';
      if (!signedIn) return atSignIn ? null : '/sign-in';
      if (atSignIn) return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/sign-in', builder: (_, _) => const SignInScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => _TabsShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/home', builder: (_, _) => const HomeScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/route', builder: (_, _) => const RouteScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/customers', builder: (_, _) => const CustomersScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/orders', builder: (_, _) => const OrdersScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/more', builder: (_, _) => const MoreScreen())]),
        ],
      ),
      GoRoute(path: '/customers/new', builder: (_, _) => const AddCustomerScreen()),
      GoRoute(
        path: '/customer/:key',
        builder: (_, state) => CustomerDetailScreen(
          customerKey: state.pathParameters['key']!,
          routeId: int.tryParse(state.uri.queryParameters['route'] ?? ''),
        ),
      ),
      GoRoute(path: '/visit/:uuid', builder: (_, state) => VisitScreen(visitUuid: state.pathParameters['uuid']!)),
      GoRoute(
        path: '/order/new',
        builder: (_, state) => OrderScreen(
          customerKey: state.uri.queryParameters['customer']!,
          visitUuid: state.uri.queryParameters['visit'],
        ),
      ),
      GoRoute(path: '/orders/:uuid', builder: (_, state) => OrderDetailScreen(uuid: state.pathParameters['uuid']!)),
      GoRoute(
        path: '/payment/new',
        builder: (_, state) => PaymentScreen(
          customerKey: state.uri.queryParameters['customer']!,
          visitUuid: state.uri.queryParameters['visit'],
        ),
      ),
      GoRoute(path: '/sync', builder: (_, _) => const SyncScreen()),
      GoRoute(path: '/day-close', builder: (_, _) => const DayCloseScreen()),
    ],
  );
});

class _TabsShell extends StatelessWidget {
  const _TabsShell({required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: shell,
        bottomNavigationBar: NavigationBar(
          selectedIndex: shell.currentIndex,
          onDestinationSelected: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
            NavigationDestination(icon: Icon(Icons.route_outlined), selectedIcon: Icon(Icons.route), label: 'Route'),
            NavigationDestination(icon: Icon(Icons.storefront_outlined), selectedIcon: Icon(Icons.storefront), label: 'Customers'),
            NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Orders'),
            NavigationDestination(icon: Icon(Icons.menu), label: 'More'),
          ],
        ),
      );
}

class BeatproApp extends ConsumerWidget {
  const BeatproApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
        title: 'BeatPro',
        debugShowCheckedModeBanner: false,
        theme: beatproTheme(Brightness.light),
        darkTheme: beatproTheme(Brightness.dark),
        routerConfig: ref.watch(routerProvider),
      );
}
