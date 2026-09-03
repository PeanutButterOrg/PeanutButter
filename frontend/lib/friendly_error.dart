String friendlyError(Object error) {
  return friendlyRequestError(
    error,
    fallback: 'Nothing to show right now. Tap Refresh, or check Settings.',
  );
}

String friendlyRequestError(
  Object error, {
  String fallback = 'Something went wrong. Try again.',
}) {
  var raw = error.toString().trim();
  if (raw.startsWith('Exception: ')) {
    raw = raw.substring('Exception: '.length).trim();
  }
  raw = _firstGraphqlMessage(raw) ?? raw;
  final sourceLower = raw.toLowerCase();
  raw = _stripPrefixes(raw);
  final lower = raw.toLowerCase();

  if (sourceLower.contains('cookie') ||
      lower.contains('cookie') ||
      sourceLower.contains('cookies required')) {
    return 'A Jackett indexer needs a login. Open Jackett, sign in to that indexer or update its cookies, then try again.';
  }
  if (sourceLower.contains('add your jackett') || lower.contains('add your jackett')) {
    return _ensureSentence(raw);
  }
  if (sourceLower.contains('jackett streaming is turned off') ||
      lower.contains('jackett streaming is turned off') ||
      sourceLower.contains('jackett streaming is disabled') ||
      lower.contains('jackett streaming is disabled')) {
    return 'Jackett streaming is turned off. Enable it in the server console.';
  }
  if (_jackettRejectedKey(sourceLower) || _jackettRejectedKey(lower)) {
    return 'Jackett rejected the API key. Copy it from Jackett and paste it in the server console.';
  }
  if (sourceLower.contains('flaresolver') || lower.contains('flaresolver') ||
      ((sourceLower.contains('jackett') || lower.contains('jackett')) &&
          (sourceLower.contains('cloudflare') || lower.contains('cloudflare')))) {
    return 'A Jackett indexer is blocked by Cloudflare. Check FlareSolverr in Jackett.';
  }
  if ((sourceLower.contains('jackett') || lower.contains('jackett')) &&
      (lower.contains('signed in') ||
          lower.contains('login') ||
          sourceLower.contains('login'))) {
    return 'A Jackett indexer needs a login. Open Jackett, sign in to that indexer or update its cookies, then try again.';
  }
  if (lower.contains('build error') ||
      sourceLower.contains('build error') ||
      ((sourceLower.contains('jackett') || lower.contains('jackett')) &&
          (lower.contains('indexers') || sourceLower.contains('indexers')))) {
    return 'Jackett’s indexers didn’t return results. Open Jackett and make sure they still work.';
  }
  if ((sourceLower.contains('jackett') || lower.contains('jackett')) &&
      (lower.contains('rate') || sourceLower.contains('rate'))) {
    return 'Jackett is being rate-limited. Wait a minute and try again.';
  }
  if (lower.contains('enough peers') ||
      lower.contains('waiting for torrent') ||
      (lower.contains('torrent') && (lower.contains('timed out') || lower.contains('timeout')))) {
    return 'Couldn’t find enough peers to start this stream. Try another result.';
  }
  if (lower.contains('playable video') || lower.contains('no video file')) {
    return 'This source doesn’t contain a playable video file. Try another result.';
  }
  if (lower.contains('try another result')) {
    return _ensureSentence(raw);
  }

  if (sourceLower.contains('metadata provider') ||
      (lower.contains('tmdb') && lower.contains('key')) ||
      (lower.contains('omdb') && lower.contains('key')) ||
      lower.contains('tmdb ') ||
      lower.contains('omdb ')) {
    return 'Couldn’t fetch metadata. Check TMDB and OMDb keys in Settings.';
  }
  if (sourceLower.contains('database error') || lower.contains('database')) {
    return 'Couldn’t read or save data. Try again.';
  }

  if (lower.contains('401') ||
      lower.contains('unauthorized') ||
      lower.contains('api token') ||
      lower.contains('missing api')) {
    return 'This app is not authorized to talk to the server. Open Settings and fetch the token from this PC, or paste the token from the machine that runs the server.';
  }
  if (lower.contains('403') || lower.contains('forbidden') || lower.contains('access denied')) {
    return 'Access denied. Check the server token in Settings.';
  }
  if (lower.contains('failed to connect') ||
      lower.contains('connection refused') ||
      lower.contains('socketexception') ||
      lower.contains('clientexception') ||
      lower.contains('xmlhttprequest') ||
      lower.contains('failed host lookup') ||
      lower.contains('network is unreachable')) {
    return 'Can’t reach the server. Check the URL in Settings.';
  }
  if (lower.contains('timed out') || lower.contains('timeout')) {
    return 'The server took too long to respond. Try again.';
  }

  if (_looksTechnical(raw) || raw.isEmpty) {
    return fallback;
  }
  return _ensureSentence(raw);
}

String? _firstGraphqlMessage(String raw) {
  final match = RegExp(r"message:\s*'([^']+)'").firstMatch(raw);
  if (match != null) return match.group(1);
  final match2 = RegExp(r'message:\s*"([^"]+)"').firstMatch(raw);
  if (match2 != null) return match2.group(1);
  return null;
}

String _stripPrefixes(String text) {
  var t = text.trim();
  const prefixes = [
    'error: ',
    'jackett: ',
    'invalid request: ',
    'metadata provider error: ',
    'internal error: ',
    'database error: ',
    'configuration error: ',
    'search error: ',
    'http client error: ',
    'io error: ',
    'not found: ',
    'unauthorized: ',
    'forbidden: ',
  ];
  var changed = true;
  while (changed) {
    changed = false;
    final lower = t.toLowerCase();
    for (final prefix in prefixes) {
      if (lower.startsWith(prefix)) {
        t = t.substring(prefix.length).trim();
        changed = true;
        break;
      }
    }
  }
  return t;
}

bool _jackettRejectedKey(String lower) {
  if (!lower.contains('jackett')) return false;
  return lower.contains('rejected') ||
      lower.contains('401') ||
      lower.contains('403') ||
      lower.contains('unauthorized') ||
      (lower.contains('api key') && (lower.contains('invalid') || lower.contains('wrong')));
}

bool _looksTechnical(String raw) {
  final lower = raw.toLowerCase();
  if (lower.contains('exception') ||
      lower.contains('statuscode') ||
      lower.contains('error[') ||
      lower.contains('stack') ||
      lower.contains('<html') ||
      lower.contains('operationexception') ||
      lower.contains('linkexception') ||
      lower.contains('graphqlerror')) {
    return true;
  }
  if (raw.contains('{') && raw.contains('}')) return true;
  if (!raw.contains(' ') && raw.length < 24) return true;
  return false;
}

String _ensureSentence(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return t;
  final first = t[0].toUpperCase();
  final rest = t.length > 1 ? t.substring(1) : '';
  var out = '$first$rest';
  if (!RegExp(r'[.!?]$').hasMatch(out)) {
    out = '$out.';
  }
  return out;
}

String emptyKindMessage({
  required String kind,
  required bool omdbConfigured,
}) {
  switch (kind) {
    case 'MOVIE':
      return 'Nothing to show in Movies yet. Tap Refresh after a metadata sync.';
    case 'SERIES':
      return 'Nothing to show in Series yet. Tap Refresh after a metadata sync.';
    case 'ANIME':
      return 'Nothing to show in Anime yet. Tap Refresh after a metadata sync.';
    default:
      return 'Nothing to show. Tap Refresh after a metadata sync.';
  }
}

String kindPlural(String kind) {
  switch (kind) {
    case 'MOVIE':
      return 'movies';
    case 'SERIES':
      return 'series';
    case 'ANIME':
      return 'anime';
    default:
      return 'titles';
  }
}

String searchHint(String kind) {
  switch (kind) {
    case 'MOVIE':
      return 'Search movies';
    case 'SERIES':
      return 'Search series';
    case 'ANIME':
      return 'Search anime';
    default:
      return 'Search titles';
  }
}

String searchEmptyTitle(String kind) {
  switch (kind) {
    case 'MOVIE':
      return 'No movies found';
    case 'SERIES':
      return 'No series found';
    case 'ANIME':
      return 'No anime found';
    default:
      return 'Nothing found';
  }
}

String searchIdleTitle(String kind) {
  switch (kind) {
    case 'MOVIE':
      return 'Find a movie to watch';
    case 'SERIES':
      return 'Find a series to watch';
    case 'ANIME':
      return 'Find an anime to watch';
    default:
      return 'Find something to watch';
  }
}

bool kindBlockedByMissingKeys(String kind, {required bool omdbConfigured}) {
  return false;
}
