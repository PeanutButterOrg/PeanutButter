/// On-device torrent streaming: the libtorrent engine on desktop, a stand-in
/// that reports "not supported" in the browser (dart:ffi doesn't exist there,
/// so importing the engine made the web build fail to compile).
library;

export 'local_torrent_types.dart';
export 'local_torrent_io.dart' if (dart.library.js_interop) 'local_torrent_web.dart';
