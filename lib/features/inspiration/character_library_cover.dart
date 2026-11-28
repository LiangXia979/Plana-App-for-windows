import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/name_query.dart';
import '../../core/util/prompt_block.dart';
import '../generate/models.dart';
import 'external/oc_sources.dart';
import 'public_tags.dart';
import 'tag_library.dart';
import 'tag_models.dart';

/// Match the name of the character or its OC block and a complete copy of
/// that entry's tags. This distinguishes costumes sharing the same alias.
class CharacterLibraryQuery {
  CharacterLibraryQuery(Iterable<(String, String)> hints) {
    for (final (name, text) in hints) {
      final key = normalizeName(name);
      if (key.isNotEmpty && text.isNotEmpty) {
        (_byName[key] ??= {}).add(text);
      }
    }
  }

  final _byName = <String, Set<String>>{};

  bool namesMatch(Iterable<String> names) =>
      names.any((name) => _byName.containsKey(normalizeName(name)));

  TagEntry? match(Iterable<TagEntry> entries) => entries.where((e) {
    if (e.category != TagCategory.character || e.positive.isEmpty) return false;
    for (final name in [e.name, ...e.aliases, e.publicId ?? e.id]) {
      final texts = _byName[normalizeName(name)];
      if (texts != null &&
          texts.any(
            (text) => PromptBlock.containsLibraryCopy(text, e.positive),
          )) {
        return true;
      }
    }
    return false;
  }).singleOrNull;
}

// External assistant lookups deliberately read text only. Resolve artwork
// through the library's own file/visitor handling only for a displayed OC.
final _externalCover = FutureProvider.autoDispose.family<String?, String>((
  ref,
  entryId,
) async {
  final repo = ref.watch(ocRepositoryProvider);
  final sources = await ref.watch(ocSourcesProvider.future);
  if (!ref.mounted) return null;
  for (final source in sources) {
    if (!entryId.startsWith('ext:${source.id}:')) continue;
    final character = source.catalog.characters
        .where((c) => entryId.startsWith(c.entryPrefix(source.id)))
        .firstOrNull;
    if (character == null) return null;
    final forms = await repo.character(
      source,
      character,
      coverEntryId: entryId,
    );
    return forms.singleOrNull?.previewUrl;
  }
  return null;
});

/// Older AI imports saved their named OC folds without a source or avatar.
/// Resolve those at display time so opening an old canvas preserves undo.
final characterLibraryCoverProvider = FutureProvider.autoDispose
    .family<String?, CharacterPrompt>((ref, char) async {
      final id = char.source;
      if (id != null && id.startsWith('ext:')) {
        return ref.watch(_externalCover(id).future);
      }
      final kind = PromptBlockKind.character;
      final folds = char.foldLinks.where(
        (f) =>
            f.temporaryCategory == kind.libraryId && f.positiveName.isNotEmpty,
      );
      if (id == null && folds.isEmpty) return null;
      final query = CharacterLibraryQuery([
        (char.name, char.positive),
        for (final f in folds)
          (
            f.positiveName
                .replaceFirst('${kind.glyph} ', '')
                .split(' · ${kind.label}')
                .first,
            f.positiveBody,
          ),
      ]);
      final local =
          ref.watch(tagLibraryProvider).value?.of(TagCategory.character) ??
          const <TagEntry>[];
      TagEntry? find(Iterable<TagEntry> entries) => id == null
          ? query.match(entries)
          : entries.where((e) => e.id == id).firstOrNull;
      final entry =
          find(local) ??
          find(
            ref.watch(visiblePublicTagsProvider(TagCategory.character)).value ??
                const [],
          );
      if (entry != null) {
        if (entry.publicId == null) return entry.previewUrl;
        return tagPreviewOf(
          entry,
          ref.watch(tagCoverPreviewsProvider(TagCategory.character)),
        );
      }
      if (id != null) return null;

      final candidates = <TagEntry>[];
      final sources = ref.watch(ocSourcesProvider).value ?? const <OcSource>[];
      final repo = ref.watch(ocRepositoryProvider);
      for (final source in sources) {
        final entries = await repo.referenceEntries(
          source,
          matches: (c) => c.forms.any((f) => query.namesMatch(c.formNames(f))),
        );
        if (!ref.mounted) return null;
        candidates.addAll(entries);
      }
      final external = query.match(candidates);
      return external == null
          ? null
          : ref.watch(_externalCover(external.id).future);
    });
