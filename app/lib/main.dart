import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'src/app.dart';
import 'src/core/local_db.dart';
import 'src/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await LocalDb.open(factory: databaseFactory, path: p.join(await getDatabasesPath(), 'beatpro.db'));
  final container = ProviderContainer(overrides: [localDbProvider.overrideWithValue(db)]);
  await container.read(sessionProvider.notifier).restore();
  // Sync quietly at start-up; the rep can keep working while it runs.
  if (container.read(sessionProvider) != null) {
    container.read(syncControllerProvider.notifier).run();
  }
  runApp(UncontrolledProviderScope(container: container, child: const BeatproApp()));
}
