import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../design/tokens.g.dart';
import '../tv.dart';
import 'tv_chrome.dart';

/// Home sections in the top bar. Movies and Series switch the home rows in
/// place; My List and Explore open their own pages.
enum HomeSection { home, movies, series }

/// The top bar shared by every platform: logo, sections, search and the
/// device square (the profile switcher once profiles exist).
class PbTopBar extends StatelessWidget {
  const PbTopBar({
    super.key,
    required this.section,
    required this.onSection,
    this.onMoveDown,
  });

  final HomeSection section;
  final ValueChanged<HomeSection> onSection;
  final VoidCallback? onMoveDown;

  @override
  Widget build(BuildContext context) {
    final tv = isAndroidTv;
    // Phones and narrow windows: the logo shrinks to its icon and the tabs
    // scroll sideways, so My List, Watched, Search and Settings stay on screen.
    final narrow = !tv && MediaQuery.sizeOf(context).width < 760;
    final tabs = <Widget>[
      _Tab(
        label: 'Home',
        selected: section == HomeSection.home,
        focusNode: TvHeaderFocus.home,
        onPressed: () => onSection(HomeSection.home),
      ),
      _Tab(
        label: 'Movies',
        selected: section == HomeSection.movies,
        focusNode: TvHeaderFocus.movies,
        onPressed: () => onSection(HomeSection.movies),
      ),
      _Tab(
        label: 'Series',
        selected: section == HomeSection.series,
        focusNode: TvHeaderFocus.series,
        onPressed: () => onSection(HomeSection.series),
      ),
      _Tab(
        label: 'Explore',
        selected: false,
        focusNode: TvHeaderFocus.explore,
        onPressed: () => context.push('/explore'),
      ),
    ];
    return SizedBox(
      height: tv ? PbSize.topBarHeightTv : PbSize.topBarHeightDesktop,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal:
              tv ? PbSpace.gutterTv : (narrow ? 12 : PbSpace.gutterDesktop),
        ),
        child: Row(
          children: [
            PbLogo(compact: narrow),
            SizedBox(width: tv ? 36 : (narrow ? 10 : 30)),
            if (narrow)
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: tabs),
                ),
              )
            else ...[
              ...tabs,
              const Spacer(),
            ],
            // My List and Watched as buttons, as before the redesign.
            TvFocus(
              child: IconButton(
                focusNode: TvHeaderFocus.favourites,
                tooltip: 'My List',
                onPressed: () => context.push('/favourites'),
                icon: Icon(Icons.favorite_rounded,
                    size: tv ? 28 : 24, color: PbColors.text),
              ),
            ),
            TvFocus(
              child: IconButton(
                focusNode: TvHeaderFocus.watched,
                tooltip: 'Watched',
                onPressed: () => context.push('/watched'),
                icon: Icon(Icons.video_library_rounded,
                    size: tv ? 28 : 24, color: PbColors.text),
              ),
            ),
            TvFocus(
              child: IconButton(
                focusNode: TvHeaderFocus.search,
                tooltip: 'Search',
                onPressed: () => context.push('/search'),
                icon: Icon(Icons.search_rounded,
                    size: tv ? 28 : 24, color: PbColors.text),
              ),
            ),
            SizedBox(width: tv ? 12 : 8),
            _DeviceSquare(focusNode: TvHeaderFocus.settings),
          ],
        ),
      ),
    );
  }
}

class PbLogo extends StatelessWidget {
  const PbLogo({super.key, this.compact = false});

  /// Icon only (narrow screens).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tv = isAndroidTv;
    final size = tv ? 32.0 : 30.0;
    final icon = ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.24),
      child: SvgPicture.asset('assets/app_icon.svg', width: size, height: size),
    );
    if (compact) return icon;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(width: 10),
        Text.rich(
          const TextSpan(
            text: 'Peanut',
            children: [
              TextSpan(text: 'Butter', style: TextStyle(color: PbColors.brand)),
            ],
          ),
          style: PbType.h2.copyWith(
              color: PbColors.text,
              fontSize: tv ? 22 : 21,
              letterSpacing: -0.2),
        ),
      ],
    );
  }
}

/// A section label; the selected one is white with an amber underline.
class _Tab extends StatefulWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.onPressed,
    this.focusNode,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final tv = isAndroidTv;
    final lit = widget.selected || _hover || _focus;
    return Padding(
      padding: EdgeInsets.only(right: tv ? 8 : 4),
      child: FocusableActionDetector(
        focusNode: widget.focusNode,
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        // Ring only for keyboard / remote focus, not after a mouse click.
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            widget.onPressed();
            return null;
          }),
        },
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: PbMotion.fast,
            padding:
                EdgeInsets.symmetric(horizontal: tv ? 14 : 10, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(PbRadius.pill),
              border: Border.all(
                color: _focus ? PbColors.focus : Colors.transparent,
                width: PbSize.focusRing,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.label,
                  style: PbType.button.copyWith(
                    fontSize: tv ? 17 : 14.5,
                    color: lit ? PbColors.text : PbColors.textMuted,
                  ),
                ),
                const SizedBox(height: 5),
                AnimatedContainer(
                  duration: PbMotion.fast,
                  height: 2,
                  width: widget.selected ? 22 : 0,
                  decoration: BoxDecoration(
                    color: PbColors.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The device square: opens Settings today; the profile switcher later.
class _DeviceSquare extends StatelessWidget {
  const _DeviceSquare({this.focusNode});

  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final size = isAndroidTv ? 36.0 : 32.0;
    return TvFocus(
      child: Tooltip(
        message: 'Settings',
        child: InkWell(
          focusNode: focusNode,
          borderRadius: BorderRadius.circular(9),
          onTap: () => context.push('/settings'),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFF0BC72), PbColors.primary],
              ),
            ),
            child: Icon(Icons.person_rounded,
                size: size * 0.62, color: PbColors.onPrimary),
          ),
        ),
      ),
    );
  }
}
