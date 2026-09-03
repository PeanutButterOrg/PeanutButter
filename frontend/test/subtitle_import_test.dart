import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peanutbutter/widgets/subtitle_import.dart';

void main() {
  test('converts vtt cues into srt', () {
    const vtt = '''WEBVTT

00:00:01.000 --> 00:00:02.500
Hello

00:00:03.000 --> 00:00:04.000
World
''';
    final parsed = parseSubtitleBytes(utf8.encode(vtt), name: 'en.vtt');
    expect(parsed, hasLength(1));
    expect(parsed.first.content, contains('00:00:01,000 --> 00:00:02,500'));
    expect(parsed.first.content, contains('Hello'));
    expect(parsed.first.language, 'en');
  });

  test('keeps srt files as-is', () {
    const srt = '''1
00:00:01,000 --> 00:00:02,000
Hi
''';
    final parsed = parseSubtitleBytes(utf8.encode(srt), name: 'movie.srt');
    expect(parsed, hasLength(1));
    expect(parsed.first.content, contains('00:00:01,000 --> 00:00:02,000'));
  });

  test('extracts every srt from a zip', () {
    final archive = Archive()
      ..addFile(ArchiveFile('en.srt', 40, utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nHi\n')))
      ..addFile(ArchiveFile('fr.srt', 40, utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nSalut\n')));
    final bytes = ZipEncoder().encode(archive);
    final parsed = parseSubtitleBytes(bytes, name: 'subs.zip');
    expect(parsed, hasLength(2));
    expect(parsed.map((s) => s.language), containsAll(['en', 'fr']));
  });

  test('rejects oversized payloads', () {
    expect(
      () => parseSubtitleBytes(List<int>.filled(kMaxSubtitleBytes + 1, 65), name: 'huge.srt'),
      throwsException,
    );
  });
}
