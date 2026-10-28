import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fitns/data/database.dart';
import 'package:fitns/data/seed_exercises.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<ExerciseRow> exercise(String name) async =>
      (db.select(db.exercises)..where((e) => e.name.equals(name))).getSingle();

  Future<WorkoutDetail> detail(int id) async =>
      (await db.watchWorkoutDetail(id).first)!;

  test('the exercise library is seeded once, with unique keys', () async {
    final all = await db.watchExercises().first;
    expect(all, hasLength(seedExercises.length));
    expect(seedExercises.map((e) => e.key).toSet(), hasLength(seedExercises.length));

    await db.seedExerciseLibrary(); // as an app update would
    expect(await db.watchExercises().first, hasLength(seedExercises.length));
  });

  test('settings are created with defaults on first read', () async {
    final s = await db.getSettings();
    expect(s.dailyStepGoal, 8000);
    expect(s.defaultRestSeconds, 90);
    expect(s.heightMm, isNull);
  });

  group('workouts', () {
    late int routineId;
    late ExerciseRow bench;
    late ExerciseRow plank;

    setUp(() async {
      bench = await exercise('Bench Press (Barbell)');
      plank = await exercise('Plank');
      routineId = await db.saveRoutine(
        name: 'Push',
        items: [
          (exerciseId: bench.id, targetSets: 3, targetReps: 8, restSeconds: 120),
          (exerciseId: plank.id, targetSets: 2, targetReps: null, restSeconds: null),
        ],
      );
    });

    test('starting from a routine copies its exercises and empty sets', () async {
      final id = await db.startWorkout(routineId: routineId);
      final w = await detail(id);
      expect(w.workout.name, 'Push');
      expect(w.entries.map((e) => e.exercise.name), [bench.name, plank.name]);
      expect(w.entries[0].sets, hasLength(3));
      expect(w.entries[0].item.targetReps, 8);
      expect(w.entries[0].item.restSeconds, 120);
      expect(w.entries[1].sets, hasLength(2));
      expect(w.entries.expand((e) => e.sets).every((s) => !s.done), isTrue);
    });

    test('only one workout can be in progress', () async {
      final first = await db.startWorkout();
      final second = await db.startWorkout(routineId: routineId);
      expect(second, first);
    });

    test('finishing drops unticked sets and empty exercises', () async {
      final id = await db.startWorkout(routineId: routineId);
      final benchSets = (await detail(id)).entries[0].sets;
      await db.updateSet(
        benchSets[0].id,
        const WorkoutSetsCompanion(reps: Value(8), weightGrams: Value(60000)),
      );
      await db.setDone(benchSets[0].id, done: true);

      await db.finishWorkout(id);

      final w = await detail(id);
      expect(w.workout.endedAt, isNotNull);
      expect(w.entries, hasLength(1)); // plank had nothing ticked
      expect(w.entries.single.sets, hasLength(1));
      expect(w.volumeGrams, 480000);
      expect(await db.activeWorkout(), isNull);
    });

    test('history totals only ticked-off sets', () async {
      final id = await db.startWorkout(routineId: routineId);
      final sets = (await detail(id)).entries[0].sets;
      for (final s in sets.take(2)) {
        await db.updateSet(
          s.id,
          const WorkoutSetsCompanion(reps: Value(10), weightGrams: Value(50000)),
        );
        await db.setDone(s.id, done: true);
      }
      await db.finishWorkout(id);

      final history = await db.watchWorkoutHistory().first;
      expect(history, hasLength(1));
      expect(history.single.setCount, 2);
      expect(history.single.exerciseCount, 1);
      expect(history.single.volumeGrams, 1000000);
    });

    test('previous sets come from the last finished workout only', () async {
      final first = await db.startWorkout(routineId: routineId);
      final set = (await detail(first)).entries[0].sets.first;
      await db.updateSet(
        set.id,
        const WorkoutSetsCompanion(reps: Value(5), weightGrams: Value(70000)),
      );
      await db.setDone(set.id, done: true);
      await db.finishWorkout(first);

      await db.startWorkout(routineId: routineId); // in progress — ignored
      final previous = await db.previousSets(bench.id);
      expect(previous.single.weightGrams, 70000);
      expect(previous.single.reps, 5);
    });

    test('an exercise added to a workout gets last time\'s set count', () async {
      final first = await db.startWorkout();
      await db.addExercisesToWorkout(first, [bench.id]);
      final item = (await detail(first)).entries.single;
      await db.addSet(item.item.id);
      await db.addSet(item.item.id);
      for (final s in (await detail(first)).entries.single.sets) {
        await db.setDone(s.id, done: true);
      }
      await db.finishWorkout(first);

      final second = await db.startWorkout();
      await db.addExercisesToWorkout(second, [bench.id]);
      expect((await detail(second)).entries.single.sets, hasLength(3));
    });

    test('a sensor-counted set fills the next unticked set', () async {
      final id = await db.startWorkout(routineId: routineId);
      final item = (await detail(id)).entries[0];
      await db.completeNextSet(item.item.id, reps: 12);
      await db.completeNextSet(item.item.id, reps: 10);

      final sets = (await detail(id)).entries[0].sets;
      expect([for (final s in sets) (s.done, s.reps)], [
        (true, 12),
        (true, 10),
        (false, null),
      ]);
    });

    test('a sensor-counted set past the plan adds one, keeping the weight', () async {
      final id = await db.startWorkout();
      await db.addExercisesToWorkout(id, [bench.id]);
      final item = (await detail(id)).entries.single.item;
      final first = (await detail(id)).entries.single.sets.single;
      await db.updateSet(
        first.id,
        const WorkoutSetsCompanion(weightGrams: Value(40000)),
      );
      await db.completeNextSet(item.id, reps: 8);
      await db.completeNextSet(item.id, reps: 7);

      final sets = (await detail(id)).entries.single.sets;
      expect(sets, hasLength(2));
      expect(sets.every((s) => s.done && s.weightGrams == 40000), isTrue);
    });

    test('deleting a workout cascades to its exercises and sets', () async {
      final id = await db.startWorkout(routineId: routineId);
      await db.deleteWorkout(id);
      expect(await db.select(db.workoutExercises).get(), isEmpty);
      expect(await db.select(db.workoutSets).get(), isEmpty);
    });

    test('deleting a routine keeps the workouts started from it', () async {
      final id = await db.startWorkout(routineId: routineId);
      await db.deleteRoutine(routineId);
      final w = await detail(id);
      expect(w.workout.routineId, isNull);
      expect(w.entries, hasLength(2));
      expect(await db.select(db.routineExercises).get(), isEmpty);
    });

    test('an exercise in use is archived, not deleted', () async {
      final custom = await db.addCustomExercise(
        name: 'Landmine Press',
        muscle: MuscleGroup.shoulders,
        equipment: Equipment.barbell,
        kind: ExerciseKind.weightReps,
      );
      final unused = await db.addCustomExercise(
        name: 'Typo',
        muscle: MuscleGroup.chest,
        equipment: Equipment.other,
        kind: ExerciseKind.reps,
      );
      final id = await db.startWorkout();
      await db.addExercisesToWorkout(id, [custom]);

      expect(await db.removeExercise(custom), isTrue);
      expect(await db.removeExercise(unused), isFalse);
      final visible = (await db.watchExercises().first).map((e) => e.id);
      expect(visible, isNot(contains(custom)));
      expect((await detail(id)).entries.single.exercise.name, 'Landmine Press');
    });
  });

  group('steps', () {
    final boot = DateTime(2026, 10, 1);

    test('books deltas to the day of the reading', () async {
      final day1 = DateTime(2026, 10, 28, 9);
      await db.recordStepCounter(counter: 1000, bootTime: boot, now: day1);
      await db.recordStepCounter(
        counter: 1800,
        bootTime: boot,
        now: day1.add(const Duration(hours: 2)),
      );
      expect(await db.watchStepsOn(day1).first, 800);

      final day2 = DateTime(2026, 10, 29, 8);
      await db.recordStepCounter(counter: 2300, bootTime: boot, now: day2);
      expect(await db.watchStepsOn(day2).first, 500);
      expect(await db.watchStepsOn(day1).first, 800);
    });

    test('a reading older than the last one booked is ignored', () async {
      // Live reading at 10:05, then the background log replays 10:00 — whose
      // lower counter would otherwise look like a reboot.
      final day = DateTime(2026, 10, 28);
      await db.recordStepCounter(counter: 1000, bootTime: boot, now: day.add(const Duration(hours: 9)));
      await db.recordStepCounter(counter: 5000, bootTime: boot, now: day.add(const Duration(hours: 10, minutes: 5)));
      await db.recordStepCounter(counter: 4900, bootTime: boot, now: day.add(const Duration(hours: 10)));
      expect(await db.watchStepsOn(day).first, 4000);

      await db.recordStepCounter(counter: 5200, bootTime: boot, now: day.add(const Duration(hours: 11)));
      expect(await db.watchStepsOn(day).first, 4200);
    });

    test('a reboot since the last reading counts the whole counter', () async {
      final before = DateTime(2026, 10, 28, 9);
      await db.recordStepCounter(counter: 5000, bootTime: boot, now: before);
      final rebootedAt = DateTime(2026, 10, 28, 12);
      await db.recordStepCounter(
        counter: 6000,
        bootTime: rebootedAt,
        now: DateTime(2026, 10, 28, 18),
      );
      expect(await db.watchStepsOn(before).first, 6000);
    });
  });

  test('body entries in one log share a time and delete together', () async {
    final at = DateTime(2026, 10, 28, 7);
    await db.addBodyEntries(at, {BodyMetric.weight: 72500, BodyMetric.waist: 815});
    expect(await db.watchBodyEntries().first, hasLength(2));
    await db.deleteBodyLog(at);
    expect(await db.watchBodyEntries().first, isEmpty);
  });
}
