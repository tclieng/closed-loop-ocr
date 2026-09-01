// lib/data/database.dart
//
// Opens the app database (sqflite) and applies versioned migrations.

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'schema.dart';

class AppDatabase {
  static const _dbName = 'closed_loop_ocr.db';
  Database? _db;

  Future<Database> get db async => _db ??= await _open();

  Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, _dbName);
    return openDatabase(
      path,
      version: currentSchemaVersion,
      onCreate: (db, v) async {
        for (final m in schemaMigrations) {
          if (m.to <= v) {
            for (final s in m.upSql) {
              await db.execute(s);
            }
          }
        }
        await db.insert('schema_meta', {
          'version': v,
          'applied_at': DateTime.now().toIso8601String(),
        });
      },
      onUpgrade: (db, oldV, newV) async {
        for (final m in schemaMigrations) {
          if (m.to > oldV && m.to <= newV) {
            for (final s in m.upSql) {
              await db.execute(s);
            }
          }
        }
      },
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
