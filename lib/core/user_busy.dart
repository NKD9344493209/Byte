/// Knows when you are touching the screen, so heavy background work (reading
/// thousands of gallery photos) can step aside while you scroll.
class UserBusy {
  UserBusy._();

  static int _last = 0;

  /// Called for every touch on the screen (see the root widget).
  static void touch() => _last = DateTime.now().millisecondsSinceEpoch;

  /// Finishes once the screen has not been touched for [quietMs] — or after
  /// [maxWaitMs] at the latest, so the work is never held back for ever.
  static Future<void> whenIdle({int quietMs = 1500, int maxWaitMs = 20000}) async {
    final start = DateTime.now().millisecondsSinceEpoch;
    while (true) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final quietFor = now - _last;
      if (quietFor >= quietMs || now - start >= maxWaitMs) return;
      final wait = quietMs - quietFor;
      await Future<void>.delayed(Duration(milliseconds: wait < 50 ? 50 : wait));
    }
  }
}
