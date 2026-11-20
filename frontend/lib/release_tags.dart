/// What a release name says about the copy, for the quality box in
/// Choose a stream: "4K" + "HDR", "1080" + "BluRay", "HEVC", "5.1".
/// Only for display: the server alone ranks sources.
class ReleaseTags {
  const ReleaseTags({this.resolution = '', this.source = '', this.codec = '', this.audio = ''});

  /// "4K", "1080", "720" or "" when the name doesn't say.
  final String resolution;

  /// The most telling one of Remux, DV, HDR, BluRay, WEB, HDTV.
  final String source;

  /// "HEVC", "H.264", "AV1" or "".
  final String codec;

  /// "Atmos", "7.1", "5.1" or "".
  final String audio;

  static bool _has(String s, String pattern) => RegExp(pattern, caseSensitive: false).hasMatch(s);

  factory ReleaseTags.parse(String name) {
    final s = ' ${name.replaceAll(RegExp(r'[._\[\]()-]'), ' ')} ';
    final resolution = _has(s, r'\b(2160p|4k|uhd)\b')
        ? '4K'
        : _has(s, r'\b1080[pi]?\b')
            ? '1080'
            : _has(s, r'\b720p?\b')
                ? '720'
                : '';
    final source = _has(s, r'\bremux\b')
        ? 'Remux'
        : _has(s, r'\b(dv|dovi|dolby vision)\b')
            ? 'DV'
            : _has(s, r'\bhdr(10)?(\+|plus)?\b')
                ? 'HDR'
                : _has(s, r'\b(blu ?ray|bdrip|brrip|bd)\b')
                    ? 'BluRay'
                    : _has(s, r'\bweb ?(dl|rip)?\b')
                        ? 'WEB'
                        : _has(s, r'\bhdtv\b')
                            ? 'HDTV'
                            : '';
    final codec = _has(s, r'\b(x265|h ?265|hevc)\b')
        ? 'HEVC'
        : _has(s, r'\bav1\b')
            ? 'AV1'
            : _has(s, r'\b(x264|h ?264|avc)\b')
                ? 'H.264'
                : '';
    final audio = _has(s, r'\batmos\b')
        ? 'Atmos'
        : _has(s, r'(?<![0-9])7 1\b')
            ? '7.1'
            : _has(s, r'(?<![0-9])5 1\b')
                ? '5.1'
                : '';
    return ReleaseTags(resolution: resolution, source: source, codec: codec, audio: audio);
  }
}
