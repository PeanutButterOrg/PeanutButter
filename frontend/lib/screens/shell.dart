import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/catalog.dart';
import '../theme.dart';
import 'browse.dart';

class ShellScreen extends ConsumerWidget {
  const ShellScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = ref.watch(selectedKindProvider);
    ref.watch(browseProvider('MOVIE'));
    ref.watch(browseProvider('SERIES'));
    ref.watch(browseProvider('ANIME'));
    return Scaffold(
      backgroundColor: PtTheme.bg,
      body: Row(
        children: [
          _Sidebar(
            kind: kind,
            onSelect: (value) => ref.read(selectedKindProvider.notifier).state = value,
          ),
          const Expanded(child: BrowseScreen()),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.kind, required this.onSelect});

  final String kind;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 88,
      color: PtTheme.sidebar,
      child: Column(
        children: [
          const SizedBox(height: 18),
          _NavItem(
            icon: Icons.movie_outlined,
            selectedIcon: Icons.movie,
            label: 'Movies',
            selected: kind == 'MOVIE',
            onTap: () => onSelect('MOVIE'),
          ),
          _NavItem(
            icon: Icons.tv_outlined,
            selectedIcon: Icons.tv,
            label: 'Series',
            selected: kind == 'SERIES',
            onTap: () => onSelect('SERIES'),
          ),
          _NavItem(
            icon: Icons.animation_outlined,
            selectedIcon: Icons.animation,
            label: 'Anime',
            selected: kind == 'ANIME',
            onTap: () => onSelect('ANIME'),
          ),
          const Spacer(),
          _NavItem(
            icon: Icons.search,
            selectedIcon: Icons.search,
            label: 'Search',
            selected: false,
            onTap: () => context.push('/search'),
          ),
          _NavItem(
            icon: Icons.settings_outlined,
            selectedIcon: Icons.settings,
            label: 'Settings',
            selected: false,
            onTap: () => context.push('/settings'),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? PtTheme.accent : PtTheme.muted;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          children: [
            Icon(selected ? selectedIcon : icon, color: color, size: 26),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
