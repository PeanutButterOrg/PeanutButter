import 'package:flutter/material.dart';

import '../models.dart';
import 'cached_art.dart';
import 'rt_badge.dart';

class HeroCard extends StatefulWidget {
  const HeroCard({
    super.key,
    required this.item,
    required this.onTap,
    this.width = 140,
    this.height = 210,
  });

  final TitleItem item;
  final VoidCallback onTap;
  final double width;
  final double height;

  @override
  State<HeroCard> createState() => _HeroCardState();
}

class _HeroCardState extends State<HeroCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: SizedBox(
          width: widget.width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Hero(
                  tag: 'poster-${widget.item.id}',
                  child: AnimatedScale(
                    scale: _hover ? 1.04 : 1,
                    duration: const Duration(milliseconds: 160),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          CachedArt(url: widget.item.posterUrl, memCacheWidth: 420),
                          if (_hover)
                            const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [Colors.transparent, Colors.black87],
                                ),
                              ),
                            ),
                          if (_hover)
                            Align(
                              alignment: Alignment.bottomLeft,
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(
                                  widget.item.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                          Positioned(
                            top: 6,
                            right: 6,
                            child: RatingBadge(item: widget.item),
                          ),
                          if (widget.item.year != null)
                            Positioned(
                              top: 6,
                              left: 6,
                              child: _Badge(
                                text: '${widget.item.year}',
                                color: Colors.black54,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
      ),
    );
  }
}

