import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// BYTE design tokens (Iteration R1c, the product redesign).
///
/// White paper and ink by day, WhatsApp-dark by night. Exactly two colours
/// carry meaning: **green = do** (buttons, links, "done"; the familiar
/// WhatsApp greens — teal-green for fills, light green for wells, bright
/// green for the mic), **amber = BYTE is listening / needs you**. Everything
/// else is ink at four strengths.
///
/// The palette is swapped in place (see [ByteColors.dark]) so every screen
/// can keep writing `ByteColors.textDim` without caring about the mode.
class ByteColors {
  ByteColors._();

  /// Flipped by [ByteApp] from the phone's setting (or the Appearance choice).
  static bool dark = false;

  // ── brand constants (usable in const contexts) ──
  /// Bright WhatsApp green — the mic, the FAB, "online" dots.
  static const Color green = Color(0xFF25D366);
  /// Teal-green — buttons and links by day (readable on white).
  static const Color greenDeep = Color(0xFF128C7E);
  /// Night green (WhatsApp dark accent).
  static const Color greenNight = Color(0xFF00A884);
  /// Light green — the chat-bubble green, for tinted wells.
  static const Color greenSoft = Color(0xFFDCF8C6);
  static const Color amber = Color(0xFFC27A08);
  static const Color amberNight = Color(0xFFFBBF24);

  // Older names some screens still use.
  static const Color teal = greenDeep;
  static const Color tealDeep = Color(0xFF075E54);
  static const Color tealNight = greenNight;

  // ── paper & ink ──
  static Color get bg => dark ? const Color(0xFF0B141A) : Colors.white;
  static Color get surface => dark ? const Color(0xFF111B21) : Colors.white;
  /// A quiet well: tiles, search boxes, the balance card.
  static Color get surface2 => dark ? const Color(0xFF1F2C34) : const Color(0xFFF0F2F5);
  static Color get text => dark ? const Color(0xFFE9EDEF) : const Color(0xFF111B21);
  static Color get textDim => dark ? const Color(0xFF8696A0) : const Color(0xFF667781);
  /// Third strength: timestamps, chevrons, placeholders.
  static Color get textFaint => dark ? const Color(0xFF5E6E78) : const Color(0xFF9AA6AE);
  static Color get border => dark ? const Color(0xFF233138) : const Color(0xFFE9EDEF);

  // ── act (green) ──
  static Color get accent => dark ? greenNight : green; // the mic green, everywhere
  /// Green for text and icons.
  static Color get accentDim => dark ? greenNight : const Color(0xFF0F7A6E);
  static Color get accentSoft => dark ? const Color(0xFF0F3D33) : greenSoft;
  static Color get onAccent => dark ? const Color(0xFF0B141A) : Colors.white;
  /// The bright one: mic button, FAB.
  static Color get accentBright => dark ? greenNight : green;

  // ── hey (amber): listening, needs you ──
  static Color get hey => dark ? amberNight : amber;
  /// Ink on an amber fill (the listening pill).
  static Color get onHey => const Color(0xFF17191C);
  static Color get heyInk => dark ? const Color(0xFFFCD56B) : const Color(0xFF8A5706);
  static Color get heySoft => dark ? const Color(0xFF2E2410) : const Color(0xFFFBF1DD);

  static Color get danger => dark ? const Color(0xFFF15C6D) : const Color(0xFFD32F2F);
  static Color get dangerSoft => dark ? const Color(0xFF3A1A1E) : const Color(0xFFFDECEC);
}

/// Spacing and radii, so screens stop inventing their own.
class ByteSpace {
  ByteSpace._();
  static const double page = 20; // side gutter
  static const double rs = 10;
  static const double rm = 16;
  static const double rl = 24;
}

/// Buttons inside a Row: the app theme makes buttons full-width
/// (minimumSize: Size.fromHeight), which overflows a Row and hides the
/// text next to it. Use this style for a button that sits beside text.
final ButtonStyle inlineButton = ButtonStyle(
  minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.compact,
);

class ByteTheme {
  static const String font = 'Manrope';
  static const List<String> fontFallback = ['NotoSansTamil'];

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness b) {
    final isDark = b == Brightness.dark;
    final bg = isDark ? const Color(0xFF0B141A) : Colors.white;
    final surface = isDark ? const Color(0xFF111B21) : Colors.white;
    final well = isDark ? const Color(0xFF1F2C34) : const Color(0xFFF0F2F5);
    final text = isDark ? const Color(0xFFE9EDEF) : const Color(0xFF111B21);
    final textDim = isDark ? const Color(0xFF8696A0) : const Color(0xFF667781);
    final faint = isDark ? const Color(0xFF5E6E78) : const Color(0xFF9AA6AE);
    final border = isDark ? const Color(0xFF233138) : const Color(0xFFE9EDEF);
    final act = isDark ? ByteColors.greenNight : ByteColors.green;
    final actInk = isDark ? ByteColors.greenNight : const Color(0xFF0F7A6E);
    final onAct = isDark ? const Color(0xFF0B141A) : Colors.white;
    final danger = isDark ? const Color(0xFFF15C6D) : const Color(0xFFD32F2F);

    final scheme = ColorScheme(
      brightness: b,
      primary: act,
      onPrimary: onAct,
      secondary: actInk,
      onSecondary: onAct,
      error: danger,
      onError: Colors.white,
      surface: surface,
      onSurface: text,
      surfaceContainerHighest: well,
      outline: border,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      fontFamily: font,
      fontFamilyFallback: fontFallback,
      // The feel: pages slide in from the right and swipe back from the left
      // edge (iOS), and taps dim instead of rippling.
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      }),
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: text.withValues(alpha: 0.06),
    );

    // One type scale. Titles are heavy and tight; body is calm; captions are dim.
    TextStyle t(double size, FontWeight w, {Color? color, double? height, double? spacing}) => TextStyle(
          fontFamily: font,
          fontFamilyFallback: fontFallback,
          fontSize: size,
          fontWeight: w,
          color: color ?? text,
          height: height,
          letterSpacing: spacing,
        );
    final textTheme = TextTheme(
      displaySmall: t(34, FontWeight.w800, height: 1.1, spacing: -0.7), // page titles
      headlineMedium: t(28, FontWeight.w800, height: 1.2, spacing: -0.5), // the Today sentence
      headlineSmall: t(22, FontWeight.w800, height: 1.2, spacing: -0.3),
      titleLarge: t(20, FontWeight.w700, height: 1.25),
      titleMedium: t(16, FontWeight.w700, height: 1.3), // list row titles
      titleSmall: t(14, FontWeight.w700, height: 1.3),
      bodyLarge: t(16, FontWeight.w500, height: 1.45),
      bodyMedium: t(14, FontWeight.w500, height: 1.45),
      bodySmall: t(13, FontWeight.w500, height: 1.4, color: textDim), // captions
      labelLarge: t(14, FontWeight.w700, height: 1.2), // buttons
      labelMedium: t(13, FontWeight.w700, height: 1.2, color: textDim), // section labels
      labelSmall: t(11, FontWeight.w700, height: 1.2, color: textDim),
    );

    final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(999));

    return base.copyWith(
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      iconTheme: IconThemeData(color: text, size: 22),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: ByteSpace.page,
        titleTextStyle: textTheme.headlineSmall,
        iconTheme: IconThemeData(color: text, size: 22),
      ),
      // Cards are for *things* (a playlist, a pocket): flat, hairline, no shadow.
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ByteSpace.rm),
          side: BorderSide(color: border),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ByteSpace.rl)),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: border,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ByteSpace.rm)),
        textStyle: textTheme.bodyMedium,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: isDark ? const Color(0xFFE9EDEF) : const Color(0xFF111B21),
        contentTextStyle: t(14, FontWeight.w600, color: isDark ? const Color(0xFF111B21) : Colors.white),
        actionTextColor: isDark ? ByteColors.greenDeep : ByteColors.green,
        behavior: SnackBarBehavior.floating,
        shape: pill,
      ),
      // FilledButton.tonal = the soft teal well with teal text (Yes / Done / Open).
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: act,
          foregroundColor: onAct,
          minimumSize: const Size.fromHeight(48),
          shape: pill,
          textStyle: textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          minimumSize: const Size.fromHeight(48),
          side: BorderSide(color: border),
          shape: pill,
          textStyle: textTheme.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: text, textStyle: textTheme.labelLarge, shape: pill), // links are ink, not green
      ),
      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: text)),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: isDark ? ByteColors.greenNight : ByteColors.green,
        foregroundColor: isDark ? const Color(0xFF0B141A) : Colors.white,
        elevation: 4,
        shape: const StadiumBorder(), // a circle for the round FAB, a pill for the extended one
        extendedTextStyle: textTheme.labelLarge,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: well,
        selectedColor: text,
        side: BorderSide.none,
        labelStyle: t(13, FontWeight.w700, color: textDim),
        secondaryLabelStyle: t(13, FontWeight.w700, color: bg),
        shape: pill,
        showCheckmark: false,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? text : well),
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? bg : textDim),
          side: const WidgetStatePropertyAll(BorderSide.none),
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
          shape: WidgetStatePropertyAll(pill),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : surface),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? act : border),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: well,
        hintStyle: t(15, FontWeight.w500, color: faint),
        labelStyle: t(14, FontWeight.w600, color: textDim),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: act, width: 1.5)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        indicatorColor: Colors.transparent,
        height: 72,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return t(11, FontWeight.w700, color: selected ? text : faint);
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(color: selected ? text : faint, size: 24);
        }),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: textDim,
        textColor: text,
        titleTextStyle: textTheme.titleMedium,
        subtitleTextStyle: textTheme.bodySmall,
        contentPadding: const EdgeInsets.symmetric(horizontal: ByteSpace.page),
        minVerticalPadding: 12,
      ),
      dividerColor: border,
      dividerTheme: DividerThemeData(color: border, space: 1, thickness: 1),
      tabBarTheme: TabBarThemeData(
        labelColor: text,
        unselectedLabelColor: faint,
        indicatorColor: text,
        dividerColor: border,
        labelStyle: textTheme.labelLarge,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: act, linearTrackColor: border),
    );
  }
}
