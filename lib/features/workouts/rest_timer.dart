import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

@immutable
class RestTimerState {
  const RestTimerState({required this.endsAt, required this.total});

  /// Wall-clock end, not a countdown — so it stays right through the app
  /// being backgrounded, where a ticking counter would stall.
  final DateTime endsAt;
  final Duration total;

  Duration remaining(DateTime now) {
    final left = endsAt.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// 1 at the start, 0 when done.
  double fraction(DateTime now) {
    if (total <= Duration.zero) return 0;
    return (remaining(now).inMilliseconds / total.inMilliseconds).clamp(0, 1);
  }
}

/// The rest between sets. App-wide rather than per screen, so leaving the
/// workout screen and coming back doesn't lose it.
class RestTimerController extends StateNotifier<RestTimerState?> {
  RestTimerController({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      super(null);

  final DateTime Function() _clock;

  void start(Duration duration) {
    state = duration <= Duration.zero
        ? null
        : RestTimerState(endsAt: _clock().add(duration), total: duration);
  }

  /// ±15 s buttons. Taking it to zero or below ends it.
  void adjust(Duration by) {
    final current = state;
    if (current == null) return;
    final endsAt = current.endsAt.add(by);
    if (!endsAt.isAfter(_clock())) {
      state = null;
      return;
    }
    state = RestTimerState(endsAt: endsAt, total: current.total + by);
  }

  void stop() => state = null;
}

final restTimerProvider =
    StateNotifierProvider<RestTimerController, RestTimerState?>(
      (ref) => RestTimerController(),
    );
