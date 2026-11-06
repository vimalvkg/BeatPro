import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'src/app.dart';
import 'src/core/local_db.dart';
import 'src/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Phones use the system SQLite; the desktop build (for testing without a
  // phone) uses SQLite through FFI.
  final DatabaseFactory factory;
  if (!kIsWeb && (Platform.isLinux || Platform.isWindows)) {
    sqfliteFfiInit();
    factory = databaseFactoryFfi;
  } else {
    factory = sqflite.databaseFactory;
  }
  final db = await LocalDb.open(factory: factory, path: p.join(await factory.getDatabasesPath(), 'beatpro.db'));
  final container = ProviderContainer(overrides: [localDbProvider.overrideWithValue(db)]);
  await container.read(sessionProvider.notifier).restore();
  // Sync quietly at start-up; the rep can keep working while it runs.
  if (container.read(sessionProvider) != null) {
    container.read(syncControllerProvider.notifier).run();
  }
  runApp(UncontrolledProviderScope(container: container, child: const BeatproApp()));
}
