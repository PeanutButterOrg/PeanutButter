import 'package:flutter/material.dart';

import '../models.dart';
import 'rt_badge.dart';

/// Compact hero meta: score · year · runtime · [PG] · genres.
class TitleMetaRow extends StatelessWidget {
  const TitleMetaRow({
    super.key,
    required this.item,
    this.maxGenres = 2,
    this.showTech = false,
  });

  final TitleItem item;
  final int maxGenres;
  final bool showTech;

  static String formatRuntime(int minutes) {
    if (minutes <= 0) return '';
    if (minutes < 60) return '${minutes}m';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }

  static String? prettyContentRating(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return null;
    final upper = value.toUpperCase();
    // Common TV / movie certificates stay short and scannable.
    const known = {
      'G',
      'PG',
      'PG-13',
      'R',
      'NC-17',
      'TV-Y',
      'TV-Y7',
      'TV-G',
      'TV-PG',
      'TV-14',
      'TV-MA',
      'NR',
      'UR',
    };
    if (known.contains(upper)) return upper;
    if (upper.startsWith('TV-') || upper.length <= 6) return upper;
    return value;
  }

  @override
  Widget build(BuildContext context) {
    final pieces = <Widget>[];

    void add(Widget child) {
      if (pieces.isNotEmpty) {
        pieces.add(const _MetaDot());
      }
      pieces.add(child);
    }

    final score = RatingBadge(item: item, inline: true);
    if (item.displayScore != null) {
      add(score);
    }

    if (item.year != null) {
      add(_MetaText('${item.year}'));
    }

    final runtime = item.runtimeMinutes;
    if (runtime != null && runtime > 0) {
      add(_MetaText(formatRuntime(runtime)));
    }

    final rating = prettyContentRating(item.contentRating);
    if (rating != null) {
      add(_ContentRatingPill(label: rating));
    }

    for (final genre in item.genres.take(maxGenres)) {
      add(_GenrePill(label: genre));
    }

    if (showTech) {
      final quality = item.bestQuality?.trim();
      if (quality != null && quality.isNotEmpty) {
        add(_MetaText(quality, muted: true));
      }
    }

    if (pieces.isEmpty) return const SizedBox.shrink();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: pieces,
      ),
    );
  }
}

class _MetaDot extends StatelessWidget {
  const _MetaDot();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Container(
        width: 3,
        height: 3,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.45),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _MetaText extends StatelessWidget {
  const _MetaText(this.text, {this.muted = false});

  final String text;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: Colors.white.withValues(alpha: muted ? 0.55 : 0.82),
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
        height: 1.1,
      ),
    );
  }
}

class _ContentRatingPill extends StatelessWidget {
  const _ContentRatingPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white.withValues(alpha: 0.55), width: 1.1),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          height: 1.1,
        ),
      ),
    );
  }
}

class _GenrePill extends StatelessWidget {
  const _GenrePill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.88),
          fontSize: 12,
          fontWeight: FontWeight.w600,
          height: 1.1,
        ),
      ),
    );
  }
}
