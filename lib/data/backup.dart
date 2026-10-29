import 'dart:convert';

import 'package:drift/drift.dart';

import '../core/branding/app_info.dart';
import 'database.dart';

/// A problem with a backup file, worded for the person holding it.
class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A backup file that parsed and checked out, not yet restored — so the user
/// can see what's in it before it replaces anything.
class BackupPreview {
  const BackupPreview._(this._data, this.exportedAt);

  final Map<String, Object?> _data;
  final DateTime exportedAt;

  int _count(String table) => (_data[table]! as List).length;

  int get workouts => _count('workouts');
  int get routines => _count('routines');
  int get bodyEntries => _count('bodyEntries');
  int get stepDays => _count('dailySteps');
}

/// Everything in FITNS as one JSON file, and back.
///
/// Restoring replaces all data — no merging — keeping every row's id, so
/// workouts still point at their exercises and sets at their workouts.
/// The step-counter watermark is left out on purpose: it belongs to the
/// phone's own counter, and a restore usually happens on a different phone.
class BackupService {
  BackupService(this._db);

  final AppDatabase _db;

  /// Bump when a change would make an older FITNS misread a backup. Older
  /// formats must stay readable.
  static const formatVersion = 1;

  static String fileName(DateTime now) =>
      'fitns-backup-${now.year}-${_two(now.month)}-${_two(now.day)}.json';

  static String _two(int n) => n.toString().padLeft(2, '0');

  Future<String> export({DateTime? now}) async {
    final db = _db;
    Future<List<Map<String, Object?>>> all<T extends DataClass>(
      TableInfo<Table, T> table,
    ) async => [for (final row in await db.select(table).get()) row.toJson()];

    final data = <String, Object?>{
      'app': AppInfo.name,
      'formatVersion': formatVersion,
      'appVersion': AppInfo.version,
      'schemaVersion': db.schemaVersion,
      'exportedAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
      'settings': (await db.getSettings()).toJson(),
      'exercises': await all(db.exercises),
      'routines': await all(db.routines),
      'routineExercises': await all(db.routineExercises),
      'workouts': await all(db.workouts),
      'workoutExercises': await all(db.workoutExercises),
      'workoutSets': await all(db.workoutSets),
      'bodyEntries': await all(db.bodyEntries),
      'dailySteps': await all(db.dailySteps),
    };
    return const JsonEncoder.withIndent(' ').convert(data);
  }

  static const _tables = [
    'exercises',
    'routines',
    'routineExercises',
    'workouts',
    'workoutExercises',
    'workoutSets',
    'bodyEntries',
    'dailySteps',
  ];

  /// Checks [text] is a FITNS backup this version can read.
  BackupPreview parse(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const BackupException("This file isn't a FITNS backup.");
    }
    if (decoded is! Map<String, Object?> || decoded['app'] != AppInfo.name) {
      throw const BackupException("This file isn't a FITNS backup.");
    }
    final Map<String, Object?> data = decoded;
    final version = data['formatVersion'];
    if (version is! int) {
      throw const BackupException("This file isn't a FITNS backup.");
    }
    if (version > formatVersion) {
      throw const BackupException(
        'This backup was made by a newer FITNS. Update the app, then restore '
        'it.',
      );
    }
    final exportedAt = DateTime.tryParse('${data['exportedAt']}');
    if (data['settings'] is! Map ||
        exportedAt == null ||
        _tables.any((t) => data[t] is! List)) {
      throw const BackupException('This backup is incomplete or damaged.');
    }
    return BackupPreview._(data, exportedAt.toLocal());
  }

  /// Replaces everything with [backup], in one transaction: if any row is
  /// bad, nothing changes.
  Future<void> restore(BackupPreview backup) async {
    final db = _db;
    final data = backup._data;
    List<Map<String, Object?>> rows(String table) =>
        (data[table]! as List).cast<Map<String, Object?>>();

    try {
      await db.transaction(() async {
        // Children before parents, for the foreign keys.
        for (final table in <TableInfo>[
          db.workoutSets,
          db.workoutExercises,
          db.workouts,
          db.routineExercises,
          db.routines,
          db.bodyEntries,
          db.dailySteps,
          db.stepWatermarks,
          db.exercises,
          db.settings,
        ]) {
          await db.delete(table).go();
        }
        // Parents before children.
        await db
            .into(db.settings)
            .insert(
              SettingRow.fromJson(data['settings']! as Map<String, Object?>),
            );
        await db.batch((b) {
          b.insertAll(
            db.exercises,
            rows('exercises').map(ExerciseRow.fromJson),
          );
          b.insertAll(db.routines, rows('routines').map(RoutineRow.fromJson));
          b.insertAll(
            db.routineExercises,
            rows('routineExercises').map(RoutineExerciseRow.fromJson),
          );
          b.insertAll(db.workouts, rows('workouts').map(WorkoutRow.fromJson));
          b.insertAll(
            db.workoutExercises,
            rows('workoutExercises').map(WorkoutExerciseRow.fromJson),
          );
          b.insertAll(
            db.workoutSets,
            rows('workoutSets').map(WorkoutSetRow.fromJson),
          );
          b.insertAll(
            db.bodyEntries,
            rows('bodyEntries').map(BodyEntryRow.fromJson),
          );
          b.insertAll(
            db.dailySteps,
            rows('dailySteps').map(DailyStepRow.fromJson),
          );
        });
        // A backup from an older FITNS lacks any built-ins added since.
        await db.seedExerciseLibrary();
      });
    } on BackupException {
      rethrow;
    } catch (_) {
      throw const BackupException(
        'This backup is damaged — nothing was changed.',
      );
    }
  }
}
