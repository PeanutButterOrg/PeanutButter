import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';

/// Shows the best available rating (RT, IMDb, TMDB/TVMaze, or AniList).
class RatingBadge extends StatelessWidget {
  const RatingBadge({
    super.key,
    required this.item,
    this.compact = true,
    this.inline = false,
  });

  final TitleItem item;
  final bool compact;
  /// Flat score for hero meta rows (no filled chip background).
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final score = item.displayScore;
    if (score == null) return const SizedBox.shrink();
    return ScoreChip(score: score, compact: compact, inline: inline);
  }
}

class ScoreChip extends StatelessWidget {
  const ScoreChip({
    super.key,
    required this.score,
    this.compact = true,
    this.inline = false,
  });

  final DisplayScore score;
  final bool compact;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    if (score.rtScore != null) {
      return RtBadge(score: score.rtScore!, compact: compact, inline: inline);
    }
    if (inline) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 15, color: Color(0xFFFFC107)),
          const SizedBox(width: 3),
          Text(
            score.label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w800,
              height: 1.1,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            score.source,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 11,
              fontWeight: FontWeight.w600,
              height: 1.1,
            ),
          ),
        ],
      );
    }
    return Container(
      padding: EdgeInsets.fromLTRB(compact ? 5 : 8, compact ? 2 : 4, compact ? 6 : 8, compact ? 2 : 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(compact ? 6 : 8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: compact ? 13 : 16, color: const Color(0xFFFFC107)),
          SizedBox(width: compact ? 3 : 5),
          Text(
            score.label,
            style: TextStyle(
              color: Colors.white,
              fontSize: compact ? 11 : 13,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
          SizedBox(width: compact ? 3 : 5),
          Text(
            score.source,
            style: TextStyle(
              color: Colors.white70,
              fontSize: compact ? 9 : 11,
              fontWeight: FontWeight.w600,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact Rotten Tomatoes score: tomato (fresh) or splat (rotten) plus percent.
class RtBadge extends StatelessWidget {
  const RtBadge({
    super.key,
    required this.score,
    this.compact = true,
    this.inline = false,
  });

  final int score;
  final bool compact;
  final bool inline;

  bool get fresh => score >= 60;

  @override
  Widget build(BuildContext context) {
    final size = inline || !compact ? (inline ? 14.0 : 18.0) : 14.0;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          size: Size.square(size),
          painter: fresh ? const _FreshTomatoPainter() : const _RottenSplatPainter(),
        ),
        SizedBox(width: compact && !inline ? 4 : 6),
        Text(
          '$score%',
          style: TextStyle(
            color: Colors.white,
            fontSize: inline ? 13 : (compact ? 11 : 13),
            fontWeight: FontWeight.w800,
            height: inline ? 1.1 : 1,
          ),
        ),
      ],
    );
    if (inline) return row;
    return Container(
      padding: EdgeInsets.fromLTRB(compact ? 5 : 8, compact ? 2 : 4, compact ? 6 : 8, compact ? 2 : 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(compact ? 6 : 8),
      ),
      child: row,
    );
  }
}

class _FreshTomatoPainter extends CustomPainter {
  const _FreshTomatoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final tomato = Paint()..color = AppTheme.rt;
    final leaf = Paint()..color = const Color(0xFF3D9A3A);
    final stem = Paint()
      ..color = const Color(0xFF2E7A2C)
      ..strokeWidth = size.width * 0.12
      ..strokeCap = StrokeCap.round;
    final body = Rect.fromLTWH(size.width * 0.08, size.height * 0.28, size.width * 0.84, size.height * 0.68);
    canvas.drawOval(body, tomato);
    canvas.drawLine(
      Offset(size.width * 0.5, size.height * 0.08),
      Offset(size.width * 0.5, size.height * 0.34),
      stem,
    );
    final leafPath = Path()
      ..moveTo(size.width * 0.5, size.height * 0.22)
      ..quadraticBezierTo(size.width * 0.18, size.height * 0.02, size.width * 0.22, size.height * 0.3)
      ..quadraticBezierTo(size.width * 0.5, size.height * 0.18, size.width * 0.5, size.height * 0.22)
      ..moveTo(size.width * 0.5, size.height * 0.22)
      ..quadraticBezierTo(size.width * 0.82, size.height * 0.02, size.width * 0.78, size.height * 0.3)
      ..quadraticBezierTo(size.width * 0.5, size.height * 0.18, size.width * 0.5, size.height * 0.22);
    canvas.drawPath(leafPath, leaf);
    final shine = Paint()..color = Colors.white.withValues(alpha: 0.28);
    canvas.drawOval(
      Rect.fromLTWH(size.width * 0.28, size.height * 0.4, size.width * 0.22, size.height * 0.16),
      shine,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _RottenSplatPainter extends CustomPainter {
  const _RottenSplatPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFF6BBF45);
    final path = Path()
      ..moveTo(size.width * 0.5, size.height * 0.08)
      ..quadraticBezierTo(size.width * 0.72, size.height * 0.0, size.width * 0.78, size.height * 0.22)
      ..quadraticBezierTo(size.width * 1.02, size.height * 0.32, size.width * 0.86, size.height * 0.5)
      ..quadraticBezierTo(size.width * 1.0, size.height * 0.78, size.width * 0.7, size.height * 0.78)
      ..quadraticBezierTo(size.width * 0.55, size.height * 1.05, size.width * 0.38, size.height * 0.82)
      ..quadraticBezierTo(size.width * 0.08, size.height * 0.9, size.width * 0.16, size.height * 0.58)
      ..quadraticBezierTo(size.width * -0.04, size.height * 0.32, size.width * 0.22, size.height * 0.24)
      ..quadraticBezierTo(size.width * 0.28, size.height * -0.02, size.width * 0.5, size.height * 0.08);
    canvas.drawPath(path, paint);
    final seed = Paint()..color = const Color(0xFF2E6B24);
    canvas.drawCircle(Offset(size.width * 0.42, size.height * 0.46), size.width * 0.06, seed);
    canvas.drawCircle(Offset(size.width * 0.58, size.height * 0.58), size.width * 0.05, seed);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
