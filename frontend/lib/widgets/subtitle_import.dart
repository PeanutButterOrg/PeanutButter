import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

const kMaxSubtitleBytes = 5 * 1024 * 1024;

class ImportedSubtitle {
  const ImportedSubtitle({
    required this.id,
    required this.label,
    required this.language,
    required this.content,
  });

  final String id;
  final String label;
  final String language;
  final String content;
}

Future<List<ImportedSubtitle>> pickSubtitlesFromStorage() async {
  final picked = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['srt', 'vtt', 'ass', 'ssa', 'zip', 'txt'],
    withData: true,
    allowMultiple: true,
  );
  if (picked == null || picked.files.isEmpty) return const [];
  final out = <ImportedSubtitle>[];
  for (final file in picked.files) {
    final bytes = file.bytes;
    if (bytes == null) continue;
    out.addAll(parseSubtitleBytes(bytes, name: file.name));
  }
  return out;
}

Future<List<ImportedSubtitle>> downloadSubtitlesFromUrl(String rawUrl) async {
  final url = rawUrl.trim();
  if (url.isEmpty) {
    throw Exception('Paste a subtitle link first.');
  }
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    throw Exception('That link isn’t a valid http address.');
  }
  final cancel = CancelToken();
  try {
    final response = await Dio().get<List<int>>(
      url,
      cancelToken: cancel,
      options: Options(
        responseType: ResponseType.bytes,
        followRedirects: true,
        receiveTimeout: const Duration(seconds: 20),
        headers: {'User-Agent': 'PeanutButter/0.2'},
      ),
      onReceiveProgress: (count, total) {
        if (count > kMaxSubtitleBytes || (total > 0 && total > kMaxSubtitleBytes)) {
          cancel.cancel('That subtitle is larger than 5 MB.');
        }
      },
    );
    final bytes = Uint8List.fromList(response.data ?? const []);
    if (bytes.isEmpty) {
      throw Exception('That link didn’t return a subtitle file.');
    }
    if (bytes.length > kMaxSubtitleBytes) {
      throw Exception('That subtitle is larger than 5 MB.');
    }
    final name = uri.pathSegments.isEmpty ? 'subtitle.srt' : uri.pathSegments.last;
    return parseSubtitleBytes(bytes, name: name);
  } on DioException catch (e) {
    if (cancel.isCancelled || (e.message ?? '').contains('5 MB')) {
      throw Exception('That subtitle is larger than 5 MB.');
    }
    throw Exception('Couldn’t download that subtitle.');
  }
}

List<ImportedSubtitle> parseSubtitleBytes(List<int> bytes, {required String name}) {
  if (bytes.length > kMaxSubtitleBytes) {
    throw Exception('That subtitle is larger than 5 MB.');
  }
  if (bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
    return _fromZip(bytes, fallbackName: name);
  }
  final text = _decodeText(bytes);
  final content = _normalizeSubtitle(text);
  if (content == null) {
    throw Exception('Couldn’t detect an SRT or VTT subtitle in that file.');
  }
  return [
    ImportedSubtitle(
      id: const Uuid().v4(),
      label: _labelFor(name),
      language: _languageFromName(name),
      content: content,
    ),
  ];
}

List<ImportedSubtitle> _fromZip(List<int> bytes, {required String fallbackName}) {
  final archive = ZipDecoder().decodeBytes(bytes, verify: false);
  final out = <ImportedSubtitle>[];
  for (final file in archive.files) {
    if (!file.isFile) continue;
    if (file.size > kMaxSubtitleBytes) continue;
    final lower = file.name.toLowerCase();
    if (!(lower.endsWith('.srt') ||
        lower.endsWith('.vtt') ||
        lower.endsWith('.ass') ||
        lower.endsWith('.ssa') ||
        lower.endsWith('.txt'))) {
      continue;
    }
    final payload = file.content;
    final content = _normalizeSubtitle(_decodeText(payload));
    if (content == null) continue;
    out.add(
      ImportedSubtitle(
        id: const Uuid().v4(),
        label: _labelFor(file.name),
        language: _languageFromName(file.name),
        content: content,
      ),
    );
  }
  if (out.isEmpty) {
    throw Exception('That zip didn’t contain an SRT or VTT subtitle.');
  }
  return out;
}

String _decodeText(List<int> bytes) {
  var data = bytes;
  if (data.length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) {
    data = data.sublist(3);
  }
  return utf8.decode(data, allowMalformed: true);
}

String? _normalizeSubtitle(String raw) {
  final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (text.isEmpty) return null;
  if (text.contains('-->')) {
    if (text.toUpperCase().startsWith('WEBVTT')) {
      return _vttToSrt(text);
    }
    return text;
  }
  if (text.contains('[Script Info]') || text.contains('Dialogue:')) {
    return text;
  }
  return null;
}

String _vttToSrt(String vtt) {
  final lines = vtt.split('\n');
  final out = StringBuffer();
  var index = 1;
  var i = 0;
  while (i < lines.length) {
    var line = lines[i].trim();
    if (line.isEmpty || line.toUpperCase().startsWith('WEBVTT') || line.toUpperCase().startsWith('NOTE')) {
      i += 1;
      continue;
    }
    if (line.contains('-->')) {
      out.writeln('$index');
      out.writeln(line.replaceAll('.', ','));
      i += 1;
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        out.writeln(lines[i]);
        i += 1;
      }
      out.writeln();
      index += 1;
      continue;
    }
    i += 1;
  }
  return out.toString().trim();
}

String _labelFor(String name) {
  final base = name.split('/').last.split('\\').last;
  final cut = base.contains('.') ? base.substring(0, base.lastIndexOf('.')) : base;
  return cut.isEmpty ? 'Subtitle' : cut;
}

String _languageFromName(String name) {
  final lower = name.toLowerCase();
  const known = {
    'en': ['en', 'eng', 'english'],
    'fr': ['fr', 'fre', 'fra', 'french'],
    'de': ['de', 'ger', 'deu', 'german'],
    'es': ['es', 'spa', 'spanish'],
    'it': ['it', 'ita', 'italian'],
    'pt': ['pt', 'por', 'portuguese'],
    'ja': ['ja', 'jpn', 'japanese'],
    'ko': ['ko', 'kor', 'korean'],
    'zh': ['zh', 'chi', 'zho', 'chinese'],
    'hi': ['hi', 'hin', 'hindi'],
    'ar': ['ar', 'ara', 'arabic'],
    'ru': ['ru', 'rus', 'russian'],
  };
  for (final entry in known.entries) {
    for (final token in entry.value) {
      if (RegExp('(?:^|[._\\-\\s])$token(?:[._\\-\\s]|\$)').hasMatch(lower)) {
        return entry.key;
      }
    }
  }
  return 'und';
}

Future<String?> promptSubtitleUrl(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        title: const Text('Add subtitle link'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'https://…/file.srt',
          ),
          onSubmitted: (value) => Navigator.pop(ctx, value.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      );
    },
  );
}
