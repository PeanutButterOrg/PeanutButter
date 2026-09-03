import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../graphql/queries.dart';
import '../providers/catalog.dart';
import '../providers/settings.dart';
import '../widgets/app_menu.dart';
import '../widgets/tv_text_field.dart';

class EditTitleScreen extends ConsumerStatefulWidget {
  const EditTitleScreen({super.key, required this.titleId});

  final String titleId;

  @override
  ConsumerState<EditTitleScreen> createState() => _EditTitleScreenState();
}

class _EditTitleScreenState extends ConsumerState<EditTitleScreen> {
  final _title = TextEditingController();
  final _year = TextEditingController();
  final _synopsis = TextEditingController();
  String _kind = 'MOVIE';
  bool _saving = false;

  bool get _isNew => widget.titleId == 'new';

  @override
  void initState() {
    super.initState();
    if (!_isNew) {
      Future.microtask(_load);
    }
  }

  Future<void> _load() async {
    final item = await ref.read(detailProvider(widget.titleId).future);
    if (item == null || !mounted) return;
    _title.text = item.title;
    _year.text = item.year?.toString() ?? '';
    _synopsis.text = item.synopsis ?? '';
    setState(() => _kind = item.kind);
  }

  @override
  void dispose() {
    _title.dispose();
    _year.dispose();
    _synopsis.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final client = ref.read(graphQLClientProvider);
    final input = {
      'kind': _kind,
      'title': _title.text.trim(),
      'year': int.tryParse(_year.text),
      'synopsis': _synopsis.text.trim(),
    };
    try {
      if (_isNew) {
        await client.mutate(MutationOptions(document: gql(CREATE_TITLE), variables: {'input': input}));
      } else {
        await client.mutate(MutationOptions(
          document: gql(UPDATE_TITLE),
          variables: {'id': widget.titleId, 'input': input},
        ));
      }
      ref.invalidate(browseProvider(_kind));
      ref.invalidate(catalogProvider);
      if (mounted) context.go('/');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(_isNew ? 'Add title' : 'Edit title'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 160),
        children: [
          TvTextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: 12),
          AppMenuButton<String>(
            hint: 'Kind',
            value: _kind,
            entries: const [
              AppMenuEntry(value: 'MOVIE', label: 'Movie'),
              AppMenuEntry(value: 'SERIES', label: 'Series'),
              AppMenuEntry(value: 'ANIME', label: 'Anime'),
            ],
            onSelected: (v) => setState(() => _kind = v),
          ),
          const SizedBox(height: 12),
          TvTextField(
            controller: _year,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Year'),
          ),
          const SizedBox(height: 12),
          TvTextField(
            controller: _synopsis,
            maxLines: 5,
            decoration: const InputDecoration(labelText: 'Synopsis'),
          ),
        ],
      ),
    );
  }
}
