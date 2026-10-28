import 'package:fitns/features/workouts/rest_timer.dart';
import 'package:fitns/features/workouts/set_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RestTimerController', () {
    var now = DateTime(2026, 10, 28, 18);
    late RestTimerController timer;
    setUp(() {
      now = DateTime(2026, 10, 28, 18);
      timer = RestTimerController(clock: () => now);
    });

    test('counts down against the wall clock', () {
      timer.start(const Duration(seconds: 90));
      now = now.add(const Duration(seconds: 30));
      expect(timer.state!.remaining(now), const Duration(seconds: 60));
      expect(timer.state!.fraction(now), closeTo(2 / 3, 0.001));
    });

    test('a zero rest starts no timer', () {
      timer.start(Duration.zero);
      expect(timer.state, isNull);
    });

    test('adjusting past zero ends it', () {
      timer.start(const Duration(seconds: 10));
      timer.adjust(const Duration(seconds: -15));
      expect(timer.state, isNull);
    });

    test('+15 extends both the end and the total', () {
      timer.start(const Duration(seconds: 60));
      timer.adjust(const Duration(seconds: 15));
      expect(timer.state!.remaining(now), const Duration(seconds: 75));
      expect(timer.state!.total, const Duration(seconds: 75));
    });
  });

  test('parseDuration reads m:ss, h:mm:ss and bare seconds', () {
    expect(parseDuration('1:30'), 90);
    expect(parseDuration('20:00'), 1200);
    expect(parseDuration('1:00:00'), 3600);
    expect(parseDuration('45'), 45);
    expect(parseDuration('0'), isNull);
    expect(parseDuration('a:b'), isNull);
    expect(parseDuration(''), isNull);
  });
}
