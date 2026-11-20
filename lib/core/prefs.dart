import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Small, non-sensitive settings (enabled modules, onboarding flag).
/// Nothing private goes here — that lives in the vault DB.
class Prefs {
  static late SharedPreferences _p;

  static const _kOnboardingDone = 'onboarding_done';
  static const _kModules = 'enabled_modules';
  static const _kUserName = 'user_name';
  static const _kKnownAvailable = 'known_available_modules';

  static Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    themeMode.value = themeModeValue;
    await _autoEnableNewModules();
  }

  /// When a module goes from "soon" to built, switch it on once so it shows
  /// up without a trip to Settings. The user can still turn it off there.
  static Future<void> _autoEnableNewModules() async {
    if (!onboardingDone) return;
    final available = [for (final m in ByteModule.all) if (m.available) m.id];
    // First run after this logic shipped: everything up to Phase 1 was known.
    final known = _p.getStringList(_kKnownAvailable) ?? const ['notes', 'capture'];
    final fresh = available.where((id) => !known.contains(id)).toList();
    if (fresh.isNotEmpty) {
      final enabled = [...enabledModules];
      for (final id in fresh) {
        if (!enabled.contains(id)) enabled.add(id);
      }
      await setEnabledModules(enabled);
    }
    await _p.setStringList(_kKnownAvailable, available);
  }

  static bool get onboardingDone => _p.getBool(_kOnboardingDone) ?? false;

  // Plain named settings for the storage app (gallery, bubble, private space…).
  static bool flag(String key, {bool or = false}) => _p.getBool(key) ?? or;
  static Future<void> setFlag(String key, bool v) => _p.setBool(key, v);
  static int number(String key, {int or = 0}) => _p.getInt(key) ?? or;
  static Future<void> setNumber(String key, int v) => _p.setInt(key, v);
  static String text(String key, {String or = ''}) => _p.getString(key) ?? or;
  static Future<void> setText(String key, String v) => _p.setString(key, v);

  /// Appearance: 'system' | 'light' | 'dark'. Screens rebuild through [themeMode].
  static final ValueNotifier<String> themeMode = ValueNotifier<String>('system');
  static String get themeModeValue => _p.getString('theme_mode') ?? 'system';
  static Future<void> setThemeMode(String v) async {
    await _p.setString('theme_mode', v);
    themeMode.value = v;
  }
  static Future<void> setOnboardingDone(bool v) =>
      _p.setBool(_kOnboardingDone, v);

  static List<String> get enabledModules =>
      _p.getStringList(_kModules) ?? const ['notes'];
  static Future<void> setEnabledModules(List<String> ids) =>
      _p.setStringList(_kModules, ids);

  static bool isEnabled(String id) => enabledModules.contains(id);

  static String get userName => _p.getString(_kUserName) ?? '';
  static Future<void> setUserName(String v) => _p.setString(_kUserName, v);

  /// Quiet hours: follow-up nudges (Firm/Harsh) never fire in this window.
  /// The reminder time itself always fires — you chose it.
  static const _kQuietStart = 'quiet_start';
  static const _kQuietEnd = 'quiet_end';
  static String get quietStart => _p.getString(_kQuietStart) ?? '23:00';
  static String get quietEnd => _p.getString(_kQuietEnd) ?? '07:00';
  static Future<void> setQuietHours(String start, String end) async {
    await _p.setString(_kQuietStart, start);
    await _p.setString(_kQuietEnd, end);
  }

  /// Default minutes behind the two alarm buttons ("Wait" and "Later").
  static const _kSnoozeMin = 'snooze_minutes';
  static const _kLaterMin = 'later_minutes';
  static int get snoozeMinutes => _p.getInt(_kSnoozeMin) ?? 5;
  static int get laterMinutes => _p.getInt(_kLaterMin) ?? 60;
  static Future<void> setSnoozeMinutes(int v) => _p.setInt(_kSnoozeMin, v);
  static Future<void> setLaterMinutes(int v) => _p.setInt(_kLaterMin, v);

  /// Daily brief: two soft notifications a day (Android). 'HH:mm'.
  static const _kBriefOn = 'brief_enabled';
  static const _kBriefAm = 'brief_morning';
  static const _kBriefPm = 'brief_evening';
  static bool get briefEnabled => _p.getBool(_kBriefOn) ?? true;
  static String get briefMorning => _p.getString(_kBriefAm) ?? '07:00';
  static String get briefEvening => _p.getString(_kBriefPm) ?? '21:00';
  static Future<void> setBrief({bool? enabled, String? morning, String? evening}) async {
    if (enabled != null) await _p.setBool(_kBriefOn, enabled);
    if (morning != null) await _p.setString(_kBriefAm, morning);
    if (evening != null) await _p.setString(_kBriefPm, evening);
  }

  /// The pledge, in the user's own words ("I, Naveen, will use BYTE to …").
  static const _kPledge = 'pledge_text';
  static const _kPledgeAt = 'pledge_at';
  static String get pledge => _p.getString(_kPledge) ?? '';
  static DateTime? get pledgedAt {
    final v = _p.getInt(_kPledgeAt);
    return v == null ? null : DateTime.fromMillisecondsSinceEpoch(v);
  }
  static Future<void> setPledge(String text) async {
    await _p.setString(_kPledge, text.trim());
    await _p.setInt(_kPledgeAt, DateTime.now().millisecondsSinceEpoch);
  }

  /// Voice: what the neckband / assistant button does, whether BYTE talks
  /// back, recognition language, and which phone features were already shown.
  static const _kTriggerMode = 'trigger_mode'; // note | smart | command
  static const _kVoiceSpeak = 'voice_speak';
  static const _kVoiceLocale = 'voice_locale';
  static const _kFeaturesSeen = 'features_seen';
  static String get triggerMode => _p.getString(_kTriggerMode) ?? 'note';
  static Future<void> setTriggerMode(String v) => _p.setString(_kTriggerMode, v);

  /// Power/home-button long-press (the assistant gesture): open | record | ignore.
  /// Read by MainActivity as `flutter.button_wake`.
  static String get buttonWake => _p.getString('button_wake') ?? 'open';
  static Future<void> setButtonWake(String v) => _p.setString('button_wake', v);
  static bool get voiceSpeak => _p.getBool(_kVoiceSpeak) ?? true;
  static Future<void> setVoiceSpeak(bool v) => _p.setBool(_kVoiceSpeak, v);
  static String get voiceLocale => _p.getString(_kVoiceLocale) ?? 'en-IN';

  /// Patient listening: seconds of silence before BYTE decides you're done (2–8).
  static int get listenPauseSec => (_p.getInt('listen_pause_sec') ?? 4).clamp(2, 8);
  static Future<void> setListenPauseSec(int v) => _p.setInt('listen_pause_sec', v.clamp(2, 8));

  /// Keep listening across pauses until you go quiet or tap Done.
  static bool get listenLong => _p.getBool('listen_long') ?? true;
  static Future<void> setListenLong(bool v) => _p.setBool('listen_long', v);
  static Future<void> setVoiceLocale(String v) => _p.setString(_kVoiceLocale, v);
  static Set<String> get featuresSeen => (_p.getStringList(_kFeaturesSeen) ?? const []).toSet();
  static Future<void> markFeaturesSeen(Iterable<String> ids) =>
      _p.setStringList(_kFeaturesSeen, {...featuresSeen, ...ids}.toList());
  static Future<void> resetFeaturesSeen() => _p.remove(_kFeaturesSeen);

  /// Home city for live answers (movies, weather, rates).
  static const _kHomeCity = 'home_city';
  static String get homeCity => _p.getString(_kHomeCity) ?? 'Coimbatore';
  static Future<void> setHomeCity(String v) => _p.setString(_kHomeCity, v.trim().isEmpty ? 'Coimbatore' : v.trim());

  /// App lock: off | biometric | pin_bio. Wealth may add a biometric too.
  static const _kAppLock = 'app_lock_mode';
  static const _kWealthBio = 'wealth_biometric';
  static String get appLockMode => _p.getString(_kAppLock) ?? 'off';
  static Future<void> setAppLockMode(String v) => _p.setString(_kAppLock, v);
  static bool get wealthBiometric => _p.getBool(_kWealthBio) ?? false;
  static Future<void> setWealthBiometric(bool v) => _p.setBool(_kWealthBio, v);

  /// True if [t] falls inside quiet hours (window may cross midnight).
  static bool isQuiet(DateTime t) {
    int mins(String s) {
      final p = s.split(':');
      return int.parse(p[0]) * 60 + int.parse(p[1]);
    }
    final a = mins(quietStart), b = mins(quietEnd);
    final m = t.hour * 60 + t.minute;
    if (a == b) return false;
    return a < b ? (m >= a && m < b) : (m >= a || m < b);
  }
}

/// Every BYTE module, in display order. `available` = built already.
class ByteModule {
  const ByteModule({
    required this.id,
    required this.name,
    required this.tagline,
    required this.available,
  });

  final String id;
  final String name;
  final String tagline;
  final bool available;

  static const all = <ByteModule>[
    ByteModule(
      id: 'notes',
      name: 'Notes',
      tagline: 'Everything you capture, searchable forever',
      available: true,
    ),
    ByteModule(
      id: 'capture',
      name: 'Voice Capture',
      tagline: 'Neckband button → idea saved',
      available: true,
    ),
    ByteModule(
      id: 'trackers',
      name: 'Trackers',
      tagline: 'Track anything you care about',
      available: true,
    ),
    ByteModule(
      id: 'library',
      name: 'Library',
      tagline: 'Photos, videos, docs, links — one search',
      available: true,
    ),
    ByteModule(
      id: 'wealth',
      name: 'Wealth',
      tagline: 'FD, RD, gold — worth today, exactly',
      available: true,
    ),
    ByteModule(
      id: 'focus',
      name: 'Focus',
      tagline: 'Lock the distractions, phone + laptop',
      available: false,
    ),
    ByteModule(
      id: 'chat',
      name: 'Ask BYTE',
      tagline: 'Ask anything about what you saved',
      available: true,
    ),
  ];

  static ByteModule byId(String id) =>
      all.firstWhere((m) => m.id == id, orElse: () => all.first);
}
