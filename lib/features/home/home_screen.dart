import 'package:flutter/material.dart';

import '../../shared/motion.dart';
import '../../shared/theme.dart';
import '../library/folders_screen.dart';
import '../library/library_screen.dart';
import '../search/search_screen.dart';

/// The shell: three tabs on a bottom bar — Library · Search · Folders.
/// That is the whole app: what you saved, finding it, and where it is filed.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  /// Set to 'library', 'search' or 'folders' to switch tab from anywhere.
  static final ValueNotifier<String?> jumpTo = ValueNotifier<String?>(null);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  // Opening BYTE: one slow sweep of green light round the edge, then it's gone.
  late final AnimationController _launch = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
  bool _launchDone = false;
  int _tab = 0;

  /// Tabs are built the first time you visit them, so opening BYTE only
  /// builds the Library. Once built, a tab keeps its state (IndexedStack).
  final Set<int> _built = {0};

  @override
  void initState() {
    super.initState();
    HomeScreen.jumpTo.addListener(_onJump);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (Motion.scale(context) == 0) {
        setState(() => _launchDone = true);
        return;
      }
      _launch.forward().whenComplete(() {
        if (mounted) setState(() => _launchDone = true);
      });
    });
  }

  @override
  void dispose() {
    HomeScreen.jumpTo.removeListener(_onJump);
    _launch.dispose();
    super.dispose();
  }

  void _onJump() {
    final id = HomeScreen.jumpTo.value;
    if (id == null) return;
    HomeScreen.jumpTo.value = null;
    switch (id) {
      case 'search':
        _go(1);
      case 'folders':
        _go(2);
      default:
        _go(0);
    }
  }

  void _go(int i) {
    if (!mounted) return;
    // Search tapped again while it is open: put the cursor in the box.
    if (i == 1 && _tab == 1) SearchScreen.focusRequest.value++;
    if (i == _tab) return;
    if (_tab == 0) LibraryScreen.left.value++;
    setState(() {
      _tab = i;
      _built.add(i);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          TabFade(
            token: _tab,
            child: IndexedStack(
              index: _tab,
              // HeroMode: a picture opening from Search must not "fly" out of
              // the Library grid that sits hidden behind it.
              children: [
                HeroMode(enabled: _tab == 0, child: const LibraryScreen()),
                HeroMode(enabled: _tab == 1, child: _built.contains(1) ? const SearchScreen() : const SizedBox.shrink()),
                HeroMode(enabled: _tab == 2, child: _built.contains(2) ? const FoldersScreen() : const SizedBox.shrink()),
              ],
            ),
          ),
          if (!_launchDone) Positioned.fill(child: EdgeGlow(animation: _launch, settle: false)),
        ],
      ),
      bottomNavigationBar: _ByteNavBar(index: _tab, onTab: _go),
    );
  }
}

/// The bottom bar: three labelled destinations.
class _ByteNavBar extends StatelessWidget {
  const _ByteNavBar({required this.index, required this.onTab});
  final int index;
  final ValueChanged<int> onTab;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: ByteColors.bg, border: Border(top: BorderSide(color: ByteColors.border))),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              _item(context, 0, Icons.photo_library_rounded, Icons.photo_library_outlined, 'Library'),
              _item(context, 1, Icons.search_rounded, Icons.search_rounded, 'Search'),
              _item(context, 2, Icons.folder_rounded, Icons.folder_outlined, 'Folders'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item(BuildContext context, int i, IconData on, IconData off, String label) {
    final selected = index == i;
    final color = selected ? ByteColors.accentDim : ByteColors.textFaint;
    return Expanded(
      child: Pressable(
        onTap: () => onTab(i),
        pressedScale: 0.9,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: Motion.d(context, 220),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
              decoration: BoxDecoration(
                color: selected ? ByteColors.accentSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Icon(selected ? on : off, color: color, size: 24),
            ),
            const SizedBox(height: 3),
            AnimatedDefaultTextStyle(
              duration: Motion.d(context, 200),
              style: TextStyle(fontFamily: 'Manrope', fontSize: 11, fontWeight: FontWeight.w700, color: selected ? ByteColors.text : ByteColors.textFaint),
              child: Text(label),
            ),
          ],
        ),
      ),
    );
  }
}
