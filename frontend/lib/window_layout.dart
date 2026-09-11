/// Prefer wide TMDB backdrops for banners; fall back to thumb / poster.
String? bestBannerUrl({
  String? backdropUrl,
  String? thumbUrl,
  String? posterUrl,
}) {
  if (backdropUrl != null && backdropUrl.isNotEmpty) return backdropUrl;
  if (thumbUrl != null && thumbUrl.isNotEmpty) return thumbUrl;
  if (posterUrl != null && posterUrl.isNotEmpty) return posterUrl;
  return null;
}
