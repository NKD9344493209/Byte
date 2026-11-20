# BYTE design rules (Iteration R1 →)

The look: white and ink by day (WhatsApp-light), WhatsApp-dark by night. Two colours carry meaning and nothing else gets colour:
- **green = do** — one green, the WhatsApp `#25D366` (`ByteColors.accent` = `accentBright`) for every filled button, the mic and the FAB; `accentSoft` light green for tinted wells with `accentDim` text inside them. Text links (`TextButton`) are ink, never green.
- **amber = BYTE is listening / needs you** (`hey`, `heyInk`, `heySoft`)
- `danger` only for destructive or failed.

Tokens live in `lib/shared/theme.dart` (`ByteColors`, `ByteSpace`), components in `lib/shared/ui.dart`. The amber listening/recording bars are one widget, `ListeningWave` in `lib/shared/wave.dart` (voice screen, assist sheet, recorder).

## Rules
1. **Lists, not cards.** Information is a `ByteList` of `ByteRow`s (hairline between rows, 20 px gutter, icon well on the left, title 16/700, caption 13 dim, trailing `Meta`/chevron/`YesNo`). `Card` only for *things*: a playlist, a pocket, the balance, a Space tile.
2. **One page title** (`PageTitle`, 34/800) on tab roots; pushed screens use the `AppBar` (22/800 title, back arrow) — never both.
3. **Section labels are sentence case and dim** (`SectionLabel('Needs you')`). No `toUpperCase()`, no `letterSpacing: 1.1`, no "·" chains in labels (use commas or " — ").
4. **One primary action per screen**, a teal `FilledButton`. Secondary = `TextButton`. Buttons inside a Row or a dialog's actions use `style: inlineButton`.
5. **Search** is `QuietSearch`; filters are `ChipRow` of `Pill`s (selected = ink pill).
6. **Type**: Manrope only; use `Theme.of(context).textTheme` roles (displaySmall title, headlineMedium the Today sentence, titleMedium row titles, bodyMedium text, bodySmall captions, labelMedium section labels). Numbers that align use `FontFeature.tabularFigures()`.
7. **Copy**: verbs on buttons ("Save changes", "Not today"), states in words ("Heard it — score 97%"), empty states say what to do (`EmptyNote`). No exclamation marks, no "Oops".
8. **Never** `const` with a `ByteColors` getter. Never a tooltip as the only explanation.
9. Spacing: gutters 20, between rows 0 (hairline), between sections 28, radii 10/16/24.
10. Dark mode is the night-ride look: same layout, no new components.
11. **Small sheets rise, they don't pop.** Anything that appears over another screen (`LeftOffSheet`) slides up 48 px with `easeOutQuint` while fading and scaling 0.97→1, swaps its content with a fade+4 % slide, and leaves in 220 ms. Buttons shrink to 0.92 while pressed and spring back (`elasticOut`). A finished thing leaves with a moment of delight (the green droplet burst), never a snackbar.
12. **Motion is one system** (`lib/shared/motion.dart`). Every tappable thing that is not a Material button is a `Pressable` (0.96 press-back, spring return, a click). `ByteList` rows arrive in a wave once. Pages use the iOS slide (swipe back from the left edge). Sheets rise over glass with `showGlassSheet`. Toggles are `ByteSwitch`. Haptics go through `Haptics.tap / confirm / heavy`. Everything reads `Motion.scale(context)` so Me → Appearance → Motion (Full / Calm / Off) and the phone's "Reduce motion" are honoured.
