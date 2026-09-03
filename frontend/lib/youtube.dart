String youtubeEmbedHtml(String videoId, {bool muted = false}) {
  final mute = muted ? '1' : '0';
  return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<meta referrer="origin">
<style>
  html, body, #player { margin: 0; padding: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
  iframe { border: 0; }
</style>
</head>
<body>
<div id="player"></div>
<script src="https://www.youtube.com/iframe_api"></script>
<script>
  var player;
  var startMuted = $mute === 1;
  function kick() {
    if (!player) return;
    try {
      player.setVolume(100);
      if (startMuted) player.mute(); else player.unMute();
      player.playVideo();
    } catch (e) {}
  }
  function onYouTubeIframeAPIReady() {
    player = new YT.Player('player', {
      width: '100%',
      height: '100%',
      videoId: ${jsonEncodeJs(videoId)},
      host: 'https://www.youtube.com',
      playerVars: {
        autoplay: 1,
        mute: startMuted ? 1 : 0,
        controls: 0,
        rel: 0,
        modestbranding: 1,
        playsinline: 1,
        iv_load_policy: 3,
        fs: 0,
        disablekb: 1,
        origin: 'https://www.youtube.com',
        widget_referrer: 'https://www.youtube.com'
      },
      events: {
        onReady: function(e) {
          kick();
          setTimeout(kick, 250);
          setTimeout(kick, 800);
        },
        onStateChange: function(e) {
          if (e.data === YT.PlayerState.CUED || e.data === YT.PlayerState.UNSTARTED) kick();
          if (e.data === YT.PlayerState.PLAYING && !startMuted) {
            e.target.unMute();
            e.target.setVolume(100);
          }
        }
      }
    });
  }
  function setMuted(value) {
    startMuted = !!value;
    if (!player) return;
    if (value) player.mute(); else { player.unMute(); player.setVolume(100); }
  }
  function playTrailer() { kick(); }
</script>
</body>
</html>
''';
}

String jsonEncodeJs(String value) {
  return "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";
}

Uri youtubeEmbedUri(String videoId, {bool muted = false}) {
  return Uri.https('www.youtube.com', '/embed/$videoId', {
    'autoplay': '1',
    'mute': muted ? '1' : '0',
    'controls': '0',
    'rel': '0',
    'modestbranding': '1',
    'playsinline': '1',
    'enablejsapi': '1',
    'iv_load_policy': '3',
    'origin': 'https://www.youtube.com',
    'widget_referrer': 'https://www.youtube.com',
  });
}

const String youtubeForcePlayJs = r'''
(function() {
  var v = document.querySelector('video');
  if (!v) return 'wait';
  v.muted = __MUTED__;
  if (!__MUTED__) v.volume = 1;
  var p = v.play();
  if (p && p.catch) p.catch(function(){});
  return v.paused ? 'paused' : 'ok';
})();
''';
