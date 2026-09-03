class ContentLanguage {
  const ContentLanguage(this.code, this.label);

  final String code;
  final String label;
}

/// ISO 639-1 codes stored for later catalog filtering by original language.
const kContentLanguages = <ContentLanguage>[
  ContentLanguage('en', 'English'),
  ContentLanguage('ja', 'Japanese'),
  ContentLanguage('ko', 'Korean'),
  ContentLanguage('zh', 'Chinese'),
  ContentLanguage('hi', 'Hindi'),
  ContentLanguage('es', 'Spanish'),
  ContentLanguage('fr', 'French'),
  ContentLanguage('de', 'German'),
  ContentLanguage('it', 'Italian'),
  ContentLanguage('pt', 'Portuguese'),
  ContentLanguage('ar', 'Arabic'),
  ContentLanguage('tr', 'Turkish'),
  ContentLanguage('ru', 'Russian'),
  ContentLanguage('th', 'Thai'),
  ContentLanguage('id', 'Indonesian'),
];

String? preferredLanguageCode(List<String> codes) {
  final selected = preferredLanguageCodes(codes);
  if (selected.isEmpty) return null;
  return selected.join(',');
}

List<String> preferredLanguageCodes(List<String> codes) {
  return [
    for (final code in codes)
      if (code.trim().isNotEmpty && code.trim().toLowerCase() != 'all')
        code.trim().toLowerCase(),
  ];
}

String languageDisplayName(String? code) {
  if (code == null || code.isEmpty || code == 'all') return 'all languages';
  if (code.contains(',')) {
    return code
        .split(',')
        .map((part) => languageDisplayName(part.trim()))
        .where((name) => name != 'all languages')
        .join(', ');
  }
  if (code == 'multi') return 'Multi';
  for (final lang in kContentLanguages) {
    if (lang.code == code) return lang.label;
  }
  return code;
}
