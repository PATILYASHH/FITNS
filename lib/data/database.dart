import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../core/dates.dart';
import '../core/steps/step_math.dart';
import '../core/units.dart';
import 'seed_exercises.dart';
import 'tables.dart';

export 'tables.dart';

part 'database.g.dart';

// ─── Read models ────────────────────────────────────────────────────────────

typedef RoutineItem = ({RoutineExerciseRow item, ExerciseRow exercise});

class RoutineDetail {
  const RoutineDetail(this.routine, this.items);

  final RoutineRow routine;
  final List<RoutineItem> items;
}

/// One exercise line of a routine as the editor hands it over to be saved.
typedef RoutineItemInput = ({
  int exerciseId,
  int targetSets,
  int? targetReps,
  int? restSeconds,
});

class WorkoutEntry {
  const WorkoutEntry({
    required this.item,
    required this.exercise,
    required this.sets,
  });

  final WorkoutExerciseRow item;
  final ExerciseRow exercise;
  final List<WorkoutSetRow> sets;
}

class WorkoutDetail {
  const WorkoutDetail(this.workout, this.entries);

  final WorkoutRow workout;
  final List<WorkoutEntry> entries;

  Iterable<WorkoutSetRow> get doneSets =>
      entries.expand((e) => e.sets).where((s) => s.done);

  int get volumeGrams => doneSets.fold(0, (sum, s) => sum + setVolumeGrams(s));
}

typedef WorkoutSummary = ({
  WorkoutRow workout,
  int exerciseCount,
  int setCount,
  int volumeGrams,
});

/// Load × reps. Zero for a bodyweight or timed set — volume is a lifting
/// number, and pretending otherwise would make a plank outweigh a squat.
int setVolumeGrams(WorkoutSetRow s) => (s.weightGrams ?? 0) * (s.reps ?? 0);

// ─── Database ───────────────────────────────────────────────────────────────

@DriftDatabase(
  tables: [
    Settings,
    Exercises,
    Routines,
    RoutineExercises,
    Workouts,
    WorkoutExercises,
    WorkoutSets,
    BodyEntries,
    StepWatermarks,
    DailySteps,
  ],
)
class AppDatabase extends _$AppDatabase {
  // `fitns` is the SQLite filename — a persistence key, not branding. Renaming
  // it later would point the app at a fresh, empty database.
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'fitns'));

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) await m.addColumn(settings, settings.allDaySteps);
    },
    beforeOpen: (details) async {
      // SQLite leaves foreign keys off unless asked, and the cascades in
      // tables.dart (a workout taking its sets with it) depend on them.
      await customStatement('PRAGMA foreign_keys = ON');
      // On every open, not just create: an app update that adds built-in
      // exercises then needs no migration. Insert-or-ignore by key, so it
      // costs a few milliseconds and never duplicates.
      await seedExerciseLibrary();
    },
  );

  // ── Settings ───────────────────────────────────────────────────────────────

  SimpleSelectStatement<$SettingsTable, SettingRow> _settingsRow() =>
      select(settings)..where((s) => s.id.equals(1));

  /// The settings row, created with defaults the first time it's asked for.
  /// Reads before it writes: an insert notifies every settings watcher, even
  /// one that ends up ignored.
  Future<SettingRow> getSettings() async {
    final row = await _settingsRow().getSingleOrNull();
    if (row != null) return row;
    await into(settings).insert(
      const SettingsCompanion(id: Value(1)),
      mode: InsertMode.insertOrIgnore,
    );
    return _settingsRow().getSingle();
  }

  Stream<SettingRow> watchSettings() async* {
    await getSettings();
    yield* _settingsRow().watchSingle();
  }

  Future<void> updateSettings(SettingsCompanion changes) async {
    await getSettings();
    await (update(settings)..where((s) => s.id.equals(1))).write(changes);
  }

  // ── Exercises ──────────────────────────────────────────────────────────────

  /// Inserts every built-in exercise whose key isn't already present. Safe to
  /// run again on any upgrade that adds to [seedExercises].
  Future<void> seedExerciseLibrary() => batch((b) {
    b.insertAll(exercises, [
      for (final e in seedExercises)
        ExercisesCompanion.insert(
          name: e.name,
          muscle: e.muscle,
          equipment: e.equipment,
          kind: e.kind,
          seedKey: Value(e.key),
        ),
    ], mode: InsertMode.insertOrIgnore);
  });

  Stream<List<ExerciseRow>> watchExercises() =>
      (select(exercises)
            ..where((e) => e.isArchived.equals(false))
            ..orderBy([(e) => OrderingTerm.asc(e.name.lower())]))
          .watch();

  Future<int> addCustomExercise({
    required String name,
    required MuscleGroup muscle,
    required Equipment equipment,
    required ExerciseKind kind,
  }) => into(exercises).insert(
    ExercisesCompanion.insert(
      name: name.trim(),
      muscle: muscle,
      equipment: equipment,
      kind: kind,
      isCustom: const Value(true),
    ),
  );

  /// Deletes an exercise nothing refers to. One that any workout or routine
  /// uses is archived instead, so history never loses a name. Returns whether
  /// it was archived.
  Future<bool> removeExercise(int id) => transaction(() async {
    final inWorkout = await (select(
      workoutExercises,
    )..where((w) => w.exerciseId.equals(id))..limit(1)).get();
    final inRoutine = await (select(
      routineExercises,
    )..where((r) => r.exerciseId.equals(id))..limit(1)).get();
    if (inWorkout.isNotEmpty || inRoutine.isNotEmpty) {
      await (update(exercises)..where((e) => e.id.equals(id))).write(
        const ExercisesCompanion(isArchived: Value(true)),
      );
      return true;
    }
    await (delete(exercises)..where((e) => e.id.equals(id))).go();
    return false;
  });

  // ── Routines ───────────────────────────────────────────────────────────────

  Stream<List<RoutineDetail>> watchRoutines() {
    final query =
        select(routines).join([
          leftOuterJoin(
            routineExercises,
            routineExercises.routineId.equalsExp(routines.id),
          ),
          leftOuterJoin(
            exercises,
            exercises.id.equalsExp(routineExercises.exerciseId),
          ),
        ])..orderBy([
          OrderingTerm.asc(routines.sort),
          OrderingTerm.asc(routines.id),
          OrderingTerm.asc(routineExercises.sort),
        ]);
    return query.watch().map((rows) {
      // Map literals keep insertion order, so the query's ordering survives.
      final byId = <int, RoutineDetail>{};
      for (final row in rows) {
        final routine = row.readTable(routines);
        final detail = byId.putIfAbsent(
          routine.id,
          () => RoutineDetail(routine, []),
        );
        final item = row.readTableOrNull(routineExercises);
        final exercise = row.readTableOrNull(exercises);
        if (item != null && exercise != null) {
          detail.items.add((item: item, exercise: exercise));
        }
      }
      return byId.values.toList();
    });
  }

  Future<RoutineDetail?> routineDetail(int id) async {
    final routine = await (select(
      routines,
    )..where((r) => r.id.equals(id))).getSingleOrNull();
    if (routine == null) return null;
    final rows =
        await (select(routineExercises).join([
                innerJoin(
                  exercises,
                  exercises.id.equalsExp(routineExercises.exerciseId),
                ),
              ])
              ..where(routineExercises.routineId.equals(id))
              ..orderBy([OrderingTerm.asc(routineExercises.sort)]))
            .get();
    return RoutineDetail(routine, [
      for (final row in rows)
        (
          item: row.readTable(routineExercises),
          exercise: row.readTable(exercises),
        ),
    ]);
  }

  /// Creates a routine ([id] null) or replaces an existing one's name and
  /// exercise list. Returns the routine's id.
  Future<int> saveRoutine({
    int? id,
    required String name,
    required List<RoutineItemInput> items,
  }) => transaction(() async {
    final int routineId;
    if (id == null) {
      routineId = await into(routines).insert(
        RoutinesCompanion.insert(
          name: name.trim(),
          sort: Value(await _nextRoutineSort()),
        ),
      );
    } else {
      routineId = id;
      await (update(routines)..where((r) => r.id.equals(id))).write(
        RoutinesCompanion(name: Value(name.trim())),
      );
      await (delete(
        routineExercises,
      )..where((r) => r.routineId.equals(id))).go();
    }
    await batch((b) {
      b.insertAll(routineExercises, [
        for (final (i, item) in items.indexed)
          RoutineExercisesCompanion.insert(
            routineId: routineId,
            exerciseId: item.exerciseId,
            sort: i,
            targetSets: Value(item.targetSets),
            targetReps: Value(item.targetReps),
            restSeconds: Value(item.restSeconds),
          ),
      ]);
    });
    return routineId;
  });

  Future<int> _nextRoutineSort() async {
    final max = routines.sort.max();
    final value = await (selectOnly(
      routines,
    )..addColumns([max])).map((r) => r.read(max)).getSingle();
    return (value ?? -1) + 1;
  }

  /// Workouts started from it keep their history; only the link is cleared.
  Future<void> deleteRoutine(int id) =>
      (delete(routines)..where((r) => r.id.equals(id))).go();

  // ── Workouts ───────────────────────────────────────────────────────────────

  SimpleSelectStatement<$WorkoutsTable, WorkoutRow> _activeWorkout() =>
      select(workouts)
        ..where((w) => w.endedAt.isNull())
        ..orderBy([(w) => OrderingTerm.desc(w.startedAt)])
        ..limit(1);

  Future<WorkoutRow?> activeWorkout() => _activeWorkout().getSingleOrNull();

  Stream<WorkoutRow?> watchActiveWorkout() =>
      _activeWorkout().watchSingleOrNull();

  /// Starts a workout, from a routine or empty. If one is already in progress
  /// that one's id comes back instead — there is only ever one.
  Future<int> startWorkout({int? routineId, DateTime? now}) =>
      transaction(() async {
        final active = await activeWorkout();
        if (active != null) return active.id;

        final start = now ?? DateTime.now();
        final routine = routineId == null
            ? null
            : await routineDetail(routineId);
        final workoutId = await into(workouts).insert(
          WorkoutsCompanion.insert(
            routineId: Value(routine?.routine.id),
            name: routine?.routine.name ?? workoutNameFor(start),
            startedAt: start,
          ),
        );
        for (final (i, entry) in (routine?.items ?? const []).indexed) {
          final itemId = await into(workoutExercises).insert(
            WorkoutExercisesCompanion.insert(
              workoutId: workoutId,
              exerciseId: entry.exercise.id,
              sort: i,
              targetReps: Value(entry.item.targetReps),
              restSeconds: Value(entry.item.restSeconds),
            ),
          );
          await _insertEmptySets(itemId, entry.item.targetSets.clamp(1, 20));
        }
        return workoutId;
      });

  /// Appends exercises to a workout, each with as many empty sets as it had
  /// last time (or one, the first time).
  Future<void> addExercisesToWorkout(int workoutId, List<int> exerciseIds) =>
      transaction(() async {
        final max = workoutExercises.sort.max();
        var sort =
            ((await (selectOnly(workoutExercises)
                          ..addColumns([max])
                          ..where(workoutExercises.workoutId.equals(workoutId)))
                        .map((r) => r.read(max))
                        .getSingle()) ??
                    -1) +
            1;
        for (final exerciseId in exerciseIds) {
          final previous = await previousSets(exerciseId);
          final itemId = await into(workoutExercises).insert(
            WorkoutExercisesCompanion.insert(
              workoutId: workoutId,
              exerciseId: exerciseId,
              sort: sort++,
            ),
          );
          await _insertEmptySets(itemId, previous.length.clamp(1, 10));
        }
      });

  Future<void> _insertEmptySets(int itemId, int count) => batch((b) {
    b.insertAll(workoutSets, [
      for (var i = 0; i < count; i++)
        WorkoutSetsCompanion.insert(workoutExerciseId: itemId, sort: i),
    ]);
  });

  Future<int> addSet(int workoutExerciseId) async {
    final max = workoutSets.sort.max();
    final last = await (selectOnly(workoutSets)
          ..addColumns([max])
          ..where(workoutSets.workoutExerciseId.equals(workoutExerciseId)))
        .map((r) => r.read(max))
        .getSingle();
    return into(workoutSets).insert(
      WorkoutSetsCompanion.insert(
        workoutExerciseId: workoutExerciseId,
        sort: (last ?? -1) + 1,
      ),
    );
  }

  /// Logs a set the motion sensors counted: fills the first unticked set of
  /// [itemId] (or a new one if all are done) and ticks it. A weight the user
  /// hasn't typed comes from the same hints the set row shows — last
  /// session's set at this position, else the set above. Returns the set's id.
  Future<int> completeNextSet(
    int itemId, {
    int? reps,
    int? durationSeconds,
    DateTime? now,
  }) => transaction(() async {
    final item = await (select(
      workoutExercises,
    )..where((w) => w.id.equals(itemId))).getSingle();
    var sets = await _setsOf(itemId);
    var index = sets.indexWhere((s) => !s.done);
    if (index < 0) {
      await addSet(itemId);
      sets = await _setsOf(itemId);
      index = sets.length - 1;
    }
    final target = sets[index];
    final previous = await previousSets(item.exerciseId);
    final weight =
        target.weightGrams ??
        (index < previous.length ? previous[index].weightGrams : null) ??
        (index > 0 ? sets[index - 1].weightGrams : null);
    await updateSet(
      target.id,
      WorkoutSetsCompanion(
        reps: reps == null ? const Value.absent() : Value(reps),
        durationSeconds: durationSeconds == null
            ? const Value.absent()
            : Value(durationSeconds),
        weightGrams: Value(weight),
        done: const Value(true),
        completedAt: Value(now ?? DateTime.now()),
      ),
    );
    return target.id;
  });

  Future<List<WorkoutSetRow>> _setsOf(int itemId) =>
      (select(workoutSets)
            ..where((s) => s.workoutExerciseId.equals(itemId))
            ..orderBy([(s) => OrderingTerm.asc(s.sort)]))
          .get();

  Future<void> updateSet(int setId, WorkoutSetsCompanion changes) =>
      (update(workoutSets)..where((s) => s.id.equals(setId))).write(changes);

  Future<void> setDone(int setId, {required bool done, DateTime? now}) =>
      updateSet(
        setId,
        WorkoutSetsCompanion(
          done: Value(done),
          completedAt: Value(done ? (now ?? DateTime.now()) : null),
        ),
      );

  Future<void> deleteSet(int setId) =>
      (delete(workoutSets)..where((s) => s.id.equals(setId))).go();

  Future<void> removeWorkoutExercise(int itemId) =>
      (delete(workoutExercises)..where((w) => w.id.equals(itemId))).go();

  Future<void> renameWorkout(int id, String name) =>
      (update(workouts)..where((w) => w.id.equals(id))).write(
        WorkoutsCompanion(name: Value(name.trim())),
      );

  /// Ends a workout. Sets never ticked off are dropped — they were a plan,
  /// not history — and so is any exercise left with nothing logged.
  Future<void> finishWorkout(int workoutId, {DateTime? now}) =>
      transaction(() async {
        final itemIds = selectOnly(workoutExercises)
          ..addColumns([workoutExercises.id])
          ..where(workoutExercises.workoutId.equals(workoutId));
        await (delete(workoutSets)..where(
              (s) => s.done.equals(false) & s.workoutExerciseId.isInQuery(itemIds),
            ))
            .go();
        await (delete(workoutExercises)..where(
              (w) =>
                  w.workoutId.equals(workoutId) &
                  notExistsQuery(
                    select(workoutSets)
                      ..where((s) => s.workoutExerciseId.equalsExp(w.id)),
                  ),
            ))
            .go();
        await (update(workouts)..where((w) => w.id.equals(workoutId))).write(
          WorkoutsCompanion(endedAt: Value(now ?? DateTime.now())),
        );
      });

  /// Discards an in-progress workout, or deletes one from history. Its
  /// exercises and sets go with it.
  Future<void> deleteWorkout(int id) =>
      (delete(workouts)..where((w) => w.id.equals(id))).go();

  Stream<WorkoutDetail?> watchWorkoutDetail(int id) {
    final query =
        select(workouts).join([
            leftOuterJoin(
              workoutExercises,
              workoutExercises.workoutId.equalsExp(workouts.id),
            ),
            leftOuterJoin(
              exercises,
              exercises.id.equalsExp(workoutExercises.exerciseId),
            ),
            leftOuterJoin(
              workoutSets,
              workoutSets.workoutExerciseId.equalsExp(workoutExercises.id),
            ),
          ])
          ..where(workouts.id.equals(id))
          ..orderBy([
            OrderingTerm.asc(workoutExercises.sort),
            OrderingTerm.asc(workoutExercises.id),
            OrderingTerm.asc(workoutSets.sort),
            OrderingTerm.asc(workoutSets.id),
          ]);
    return query.watch().map((rows) {
      if (rows.isEmpty) return null;
      final entries = <int, WorkoutEntry>{};
      for (final row in rows) {
        final item = row.readTableOrNull(workoutExercises);
        final exercise = row.readTableOrNull(exercises);
        if (item == null || exercise == null) continue;
        final entry = entries.putIfAbsent(
          item.id,
          () => WorkoutEntry(item: item, exercise: exercise, sets: []),
        );
        final set = row.readTableOrNull(workoutSets);
        if (set != null) entry.sets.add(set);
      }
      return WorkoutDetail(
        rows.first.readTable(workouts),
        entries.values.toList(),
      );
    });
  }

  /// Finished workouts, newest first, each with its totals.
  Stream<List<WorkoutSummary>> watchWorkoutHistory({int? limit}) {
    final exerciseCount = workoutExercises.id.count(distinct: true);
    final setCount = workoutSets.id.count();
    final volume = (workoutSets.weightGrams * workoutSets.reps).sum();
    final query =
        select(workouts).join([
            leftOuterJoin(
              workoutExercises,
              workoutExercises.workoutId.equalsExp(workouts.id),
            ),
            leftOuterJoin(
              workoutSets,
              workoutSets.workoutExerciseId.equalsExp(workoutExercises.id) &
                  workoutSets.done.equals(true),
            ),
          ])
          ..where(workouts.endedAt.isNotNull())
          ..groupBy([workouts.id])
          ..orderBy([OrderingTerm.desc(workouts.startedAt)])
          ..addColumns([exerciseCount, setCount, volume]);
    if (limit != null) query.limit(limit);
    return query.watch().map(
      (rows) => [
        for (final row in rows)
          (
            workout: row.readTable(workouts),
            exerciseCount: row.read(exerciseCount) ?? 0,
            setCount: row.read(setCount) ?? 0,
            volumeGrams: row.read(volume) ?? 0,
          ),
      ],
    );
  }

  /// The ticked-off sets from the last finished workout that included
  /// [exerciseId] — what the "Previous" column shows. An in-progress workout
  /// never counts: it has no end yet.
  Future<List<WorkoutSetRow>> previousSets(int exerciseId) async {
    final latest =
        await (select(workoutExercises).join([
                innerJoin(
                  workouts,
                  workouts.id.equalsExp(workoutExercises.workoutId),
                ),
              ])
              ..where(
                workoutExercises.exerciseId.equals(exerciseId) &
                    workouts.endedAt.isNotNull(),
              )
              ..orderBy([
                OrderingTerm.desc(workouts.startedAt),
                OrderingTerm.desc(workoutExercises.id),
              ])
              ..limit(1))
            .getSingleOrNull();
    if (latest == null) return const [];
    final itemId = latest.readTable(workoutExercises).id;
    return (select(workoutSets)
          ..where((s) => s.workoutExerciseId.equals(itemId) & s.done.equals(true))
          ..orderBy([(s) => OrderingTerm.asc(s.sort)]))
        .get();
  }

  // ── Body ───────────────────────────────────────────────────────────────────

  /// One log: every metric in [values] shares the moment [at].
  Future<void> addBodyEntries(DateTime at, Map<BodyMetric, int> values) =>
      batch((b) {
        b.insertAll(bodyEntries, [
          for (final MapEntry(:key, :value) in values.entries)
            BodyEntriesCompanion.insert(
              measuredAt: at,
              metric: key,
              value: value,
            ),
        ]);
      });

  /// Newest first.
  Stream<List<BodyEntryRow>> watchBodyEntries() =>
      (select(bodyEntries)..orderBy([
            (e) => OrderingTerm.desc(e.measuredAt),
            (e) => OrderingTerm.asc(e.id),
          ]))
          .watch();

  /// Deletes a whole log — every metric recorded at [at].
  Future<void> deleteBodyLog(DateTime at) =>
      (delete(bodyEntries)..where((e) => e.measuredAt.equals(at))).go();

  // ── Steps ──────────────────────────────────────────────────────────────────

  /// Books one reading of the step counter. [bootTime] is when the phone
  /// last booted — if that is after the previous reading, the counter has
  /// restarted from zero in between.
  ///
  /// Steps walked while nothing was reading are booked to the day of the
  /// reading that finally notices them; the counter can't say when they
  /// happened. The background service keeps that gap to a few minutes.
  ///
  /// A reading no newer than the last one booked is ignored. Readings arrive
  /// from two places — live while the app is open, and the background
  /// service's log replayed on the next launch — so an old logged reading can
  /// turn up after a newer live one. Booking it would look like the counter
  /// went down, i.e. a reboot, and count the whole total again. Skipping it
  /// loses nothing: the counter is cumulative, so the next reading carries it.
  Future<void> recordStepCounter({
    required int counter,
    required DateTime bootTime,
    DateTime? now,
  }) => transaction(() async {
    final at = now ?? DateTime.now();
    final mark = await select(stepWatermarks).getSingleOrNull();
    if (mark != null && !at.isAfter(mark.readAt)) return;
    final delta = stepDelta(
      previous: mark?.counter,
      current: counter,
      rebootedSince: mark != null && bootTime.isAfter(mark.readAt),
    );
    if (delta > 0) {
      await into(dailySteps).insert(
        DailyStepsCompanion.insert(day: dayKey(at), steps: Value(delta)),
        onConflict: DoUpdate(
          (old) => DailyStepsCompanion.custom(
            steps: old.steps + Constant(delta),
          ),
        ),
      );
    }
    // `id` must be explicit: an INTEGER PRIMARY KEY is SQLite's rowid, so
    // leaving it out allocates a fresh row instead of using the default 1.
    await into(stepWatermarks).insertOnConflictUpdate(
      StepWatermarksCompanion.insert(
        id: const Value(1),
        counter: counter,
        readAt: at,
      ),
    );
  });

  Stream<int> watchStepsOn(DateTime day) =>
      (select(dailySteps)..where((d) => d.day.equals(dayKey(day))))
          .watchSingleOrNull()
          .map((row) => row?.steps ?? 0);

  /// Days with steps from [from] onwards, oldest first. Days with none have
  /// no row.
  Stream<List<DailyStepRow>> watchStepsSince(DateTime from) =>
      (select(dailySteps)
            ..where((d) => d.day.isBiggerOrEqualValue(dayKey(from)))
            ..orderBy([(d) => OrderingTerm.asc(d.day)]))
          .watch();
}
