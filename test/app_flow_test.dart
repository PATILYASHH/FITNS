import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fitns/app.dart';
import 'package:fitns/core/motion/motion_sensors.dart';
import 'package:fitns/core/motion/rep_detectors.dart';
import 'package:fitns/core/platform/document_files.dart';
import 'package:fitns/core/steps/step_sensor.dart';
import 'package:fitns/data/database.dart';
import 'package:fitns/data/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeStepSensor extends StepSensor {
  const FakeStepSensor(this._status);

  final StepSensorStatus _status;

  @override
  Future<StepSensorStatus> status() async => _status;

  @override
  Future<StepSensorStatus> requestPermission() async => _status;

  @override
  Stream<StepReading> readings() => const Stream.empty();

  @override
  Future<void> setBackgroundCounting(bool on) async {}

  @override
  Future<List<StepReading>> drainLog() async => const [];
}

/// Sensors the test drives by hand.
/// Android's file pickers, replaced by one remembered file.
class FakeDocumentFiles extends DocumentFiles {
  String? saved;
  String? savedName;

  @override
  Future<bool> saveText({
    required String name,
    required String content,
    String mime = 'application/json',
  }) async {
    savedName = name;
    saved = content;
    return true;
  }

  @override
  Future<String?> openText() async => saved;
}

class FakeMotionSensors extends MotionSensors {
  final samples$ = StreamController<MotionSample>.broadcast();
  bool screenOn = false;

  @override
  Future<MotionAvailability> availability() async =>
      const MotionAvailability(accelerometer: true, proximity: true);

  @override
  Stream<MotionSample> samples(MotionSensorKind kind) => samples$.stream;

  @override
  Future<void> keepScreenOn(bool on) async => screenOn = on;
}

/// The app has running clocks (workout timer, rest timer), so the tree never
/// "settles" — pump a fixed number of frames instead, letting the database
/// work happen in real async between them.
Future<void> settle(WidgetTester tester) async {
  // 10 × 100 ms outlasts any page transition.
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  Future<AppDatabase> pumpApp(
    WidgetTester tester, {
    StepSensorStatus steps = StepSensorStatus.granted,
    MotionSensors motion = const MotionSensors(),
    DocumentFiles files = const DocumentFiles(),
    Future<void> Function(AppDatabase db)? seed,
  }) async {
    // A typical phone: 360 × 780 dp.
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    if (seed != null) await tester.runAsync(() => seed(db));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dbProvider.overrideWithValue(db),
          stepSensorProvider.overrideWithValue(FakeStepSensor(steps)),
          motionSensorsProvider.overrideWithValue(motion),
          documentFilesProvider.overrideWithValue(files),
        ],
        child: const FitnsApp(),
      ),
    );
    await settle(tester);
    return db;
  }

  testWidgets('log a workout from empty to finished', (tester) async {
    await pumpApp(tester);
    expect(find.text('Steps'), findsOneWidget);

    await tester.tap(find.text('Start workout'));
    await settle(tester);
    expect(find.text('Add an exercise to start logging.'), findsOneWidget);

    await tester.tap(find.text('Add exercises'));
    await settle(tester);
    await tester.tap(find.text('Bench Press (Barbell)'));
    await settle(tester);
    await tester.tap(find.text('Add 1'));
    await settle(tester);
    expect(find.text('Bench Press (Barbell)'), findsOneWidget);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '60');
    await tester.enterText(fields.at(1), '8');
    await settle(tester);
    await tester.tap(find.byIcon(Icons.check_circle_outline));
    await settle(tester);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.text('Rest'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Finish'));
    await settle(tester);
    expect(find.text('Finish workout?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Finish'));
    await settle(tester);

    expect(find.text('60 kg × 8'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('a routine starts with its exercises and target sets', (
    tester,
  ) async {
    final db = await pumpApp(tester);
    final squat = await tester.runAsync(
      () => (db.select(
        db.exercises,
      )..where((e) => e.name.equals('Squat (Barbell)'))).getSingle(),
    );
    await tester.runAsync(
      () => db.saveRoutine(
        name: 'Legs',
        items: [
          (
            exerciseId: squat!.id,
            targetSets: 4,
            targetReps: 5,
            restSeconds: 180,
          ),
        ],
      ),
    );
    await settle(tester);

    await tester.tap(find.text('Legs')); // the quick-start chip on Today
    await settle(tester);
    expect(find.text('Squat (Barbell)'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsNWidgets(4));
    // Target reps are only a hint until typed or ticked.
    final repsField = tester.widget<TextField>(find.byType(TextField).at(1));
    expect(repsField.controller!.text, isEmpty);
    expect(repsField.decoration!.hintText, '5');

    // Ticking an empty set takes the hint as what was done.
    await tester.tap(find.byIcon(Icons.check_circle_outline).first);
    await settle(tester);
    final sets = await tester.runAsync(() => db.select(db.workoutSets).get());
    expect(sets!.where((s) => s.done).single.reps, 5);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('log a weigh-in on the Body tab', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Body').last);
    await settle(tester);

    await tester.tap(find.text('Log'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Weight'), '72.5');
    await tester.tap(find.text('Save'));
    await settle(tester);

    expect(find.text('72.5 kg'), findsWidgets);
    expect(find.text('Add your height to see your BMI.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('push-ups counted by the proximity sensor become a set', (
    tester,
  ) async {
    final motion = FakeMotionSensors();
    final db = await pumpApp(
      tester,
      motion: motion,
      seed: (db) async {
        final pushUp = await (db.select(
          db.exercises,
        )..where((e) => e.name.equals('Push-up'))).getSingle();
        final id = await db.startWorkout();
        await db.addExercisesToWorkout(id, [pushUp.id]);
      },
    );

    await tester.tap(find.text('Resume'));
    await settle(tester);
    await tester.tap(find.byTooltip('Count with sensors'));
    await settle(tester);
    expect(find.text('Phone on the floor, face up'), findsOneWidget);

    await tester.tap(find.text('Start counting'));
    await settle(tester);
    expect(find.text('Get into position'), findsOneWidget);
    expect(motion.screenOn, isTrue);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await settle(tester);

    // Five push-ups: chest away, then near, each ~1.2 s.
    var t = Duration.zero;
    motion.samples$.add(ProximitySample(t, near: false));
    for (var i = 0; i < 5; i++) {
      t += const Duration(milliseconds: 700);
      motion.samples$.add(ProximitySample(t, near: true));
      t += const Duration(milliseconds: 500);
      motion.samples$.add(ProximitySample(t, near: false));
    }
    await settle(tester);
    expect(find.text('5'), findsOneWidget);

    await tester.tap(find.text('+1')); // one the sensor missed
    await settle(tester);
    await tester.tap(find.text('Done — log set'));
    await settle(tester);

    final sets = await tester.runAsync(() => db.select(db.workoutSets).get());
    expect(sets!.single.done, isTrue);
    expect(sets.single.reps, 6);
    expect(motion.screenOn, isFalse);
    expect(find.text('Rest'), findsOneWidget); // rest timer started
    expect(tester.takeException(), isNull);
    await motion.samples$.close();
    await unmount(tester);
  });

  testWidgets('a finished workout can be corrected from history', (
    tester,
  ) async {
    final db = await pumpApp(
      tester,
      seed: (db) async {
        final bench = await (db.select(
          db.exercises,
        )..where((e) => e.name.equals('Bench Press (Barbell)'))).getSingle();
        final id = await db.startWorkout(now: DateTime(2026, 10, 27, 18));
        await db.addExercisesToWorkout(id, [bench.id]);
        final set =
            (await db.watchWorkoutDetail(id).first)!.entries.single.sets.single;
        await db.updateSet(
          set.id,
          const WorkoutSetsCompanion(reps: Value(8), weightGrams: Value(6000)),
        );
        await db.setDone(set.id, done: true);
        await db.finishWorkout(id, now: DateTime(2026, 10, 27, 19));
      },
    );

    await tester.tap(find.text('Workouts').last);
    await settle(tester);
    await tester.tap(find.text('Evening workout'));
    await settle(tester);
    expect(find.text('6 kg × 8'), findsOneWidget); // meant 60

    await tester.tap(find.byTooltip('Edit workout'));
    await settle(tester);
    expect(find.text('Done'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsNothing); // no ticks
    await tester.enterText(find.byType(TextField).first, '60');
    await settle(tester);
    await tester.tap(find.text('Done'));
    await settle(tester);

    expect(find.text('60 kg × 8'), findsOneWidget);
    final sets = await tester.runAsync(() => db.select(db.workoutSets).get());
    expect(sets!.single.weightGrams, 60000);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('back up from Settings, then restore over newer changes', (
    tester,
  ) async {
    final files = FakeDocumentFiles();
    final db = await pumpApp(
      tester,
      files: files,
      seed: (db) => db.addBodyEntries(DateTime(2026, 10, 27, 7), {
        BodyMetric.weight: 72500,
      }),
    );

    await tester.tap(find.text('Settings').last);
    await settle(tester);
    await tester.scrollUntilVisible(find.text('Back up'), 200);
    await tester.tap(find.text('Back up'));
    await settle(tester);
    expect(files.saved, contains('"formatVersion"'));
    expect(files.savedName, startsWith('fitns-backup-'));
    expect(find.text('Backup saved'), findsOneWidget);

    // Something logged after the backup — the restore takes it away.
    await tester.runAsync(
      () => db.addBodyEntries(DateTime(2026, 10, 28, 7), {
        BodyMetric.weight: 71000,
      }),
    );
    await tester.tap(find.text('Restore'));
    await settle(tester);
    expect(find.text('Restore this backup?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Restore'));
    await settle(tester);

    final entries = await tester.runAsync(
      () => db.select(db.bodyEntries).get(),
    );
    expect(entries!.map((e) => e.value), [72500]);
    expect(find.text('Backup restored'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('every tab renders without errors', (tester) async {
    await pumpApp(tester, steps: StepSensorStatus.denied);
    expect(find.text('Turn on step counting'), findsOneWidget);
    for (final tab in ['Workouts', 'Body', 'Settings', 'Today']) {
      await tester.tap(find.text(tab).last);
      await settle(tester);
    }
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });
}
