// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:path/path.dart' as p;

import 'extractor.dart';
import 'models.dart';
import 'wrapper.dart';

/// Diagnostic codes indicating an unresolved illustrative placeholder symbol
/// in a documentation snippet.
const Set<String> placeholderSymbolDiagnosticCodes = {
  'undefined_identifier',
  'undefined_unqualified_name_read',
  'undefined_unqualified_name_write',
  'undefined_function',
  'undefined_class',
  'undefined_method',
  'undefined_annotation',
  'non_type_as_type_argument',
  'uri_does_not_exist',
  'creation_with_non_type',
  'extends_non_class',
  'duplicate_import',
  'body_might_complete_normally_nullable',
};

/// Diagnostics that cascade when an unbound placeholder symbol evaluates to
/// `InvalidType`.
const Set<String> cascadingUnboundDiagnosticCodes = {
  'non_bool_condition',
  'unchecked_use_of_nullable_value',
  'dead_code',
  'non_constant_list_element',
  'argument_type_not_assignable',
  'ambiguous_extension_member_access',
  'extra_positional_arguments',
};

/// Diagnostics that cascade when a class extends an unresolved superclass
/// (`extends_non_class`, e.g. `StatelessWidget` when `package:flutter` is not
/// in the package config).
const Set<String> cascadingUnresolvedSuperclassCodes = {
  'super_formal_parameter_without_associated_named',
  'override_on_non_overriding_member',
  'undefined_super_member_read',
};

/// Analyzes Dart code blocks in Markdown files using `package:analyzer` and
/// an in-memory [OverlayResourceProvider].
class MarkdownDartAnalyzer {
  MarkdownDartAnalyzer({this.config = const MarkdownAnalyzeConfig()});

  final MarkdownAnalyzeConfig config;

  /// Analyzes all `.md` files under [markdownRoot] using [contextRoot] as the
  /// Dart analysis context root.
  Future<MarkdownAnalysisResult> analyzeDirectory({
    required String contextRoot,
    String? markdownRoot,
  }) async {
    final absContextRoot = p.normalize(p.absolute(contextRoot));
    final absMdRoot = p.normalize(p.absolute(markdownRoot ?? contextRoot));

    final mdFiles =
        Directory(absMdRoot).listSync(recursive: true).whereType<File>().where((
          f,
        ) {
          if (!f.path.endsWith('.md')) return false;
          final parts = p.split(p.relative(f.path, from: absMdRoot));
          return !parts.any(config.excludedPathSegments.contains);
        }).toList()..sort((a, b) => a.path.compareTo(b.path));

    return analyzeFiles(
      contextRoot: absContextRoot,
      markdownRoot: absMdRoot,
      markdownFiles: mdFiles,
    );
  }

  /// Analyzes the specified [markdownFiles] relative to [markdownRoot] using
  /// [contextRoot] as the Dart analysis context root.
  Future<MarkdownAnalysisResult> analyzeFiles({
    required String contextRoot,
    required String markdownRoot,
    required List<File> markdownFiles,
  }) async {
    final absContextRoot = p.normalize(p.absolute(contextRoot));
    final absMdRoot = p.normalize(p.absolute(markdownRoot));
    final featureSet = buildSnippetFeatureSet(
      sdkLanguageVersion: config.sdkLanguageVersion,
      enabledExperiments: config.enabledExperiments,
    );

    final provider = OverlayResourceProvider(PhysicalResourceProvider.INSTANCE);
    var stamp = 1;

    final mergedConfigJson = buildMergedPackageConfigJson(
      targetRoot: absContextRoot,
      fallbackPackageConfigPath: config.fallbackPackageConfigPath,
    );
    if (mergedConfigJson != null) {
      provider.setOverlay(
        p.join(absContextRoot, '.dart_tool', 'package_config.json'),
        content: mergedConfigJson,
        modificationStamp: stamp++,
      );
    }

    final pubspecPath = p.join(absContextRoot, 'pubspec.yaml');
    if (!File(pubspecPath).existsSync()) {
      provider.setOverlay(
        pubspecPath,
        content:
            'name: _standalone_markdown_target\n'
            'environment:\n'
            '  sdk: ^${config.sdkLanguageVersion}\n',
        modificationStamp: stamp++,
      );
    }

    final analysisOptionsPath = p.join(absContextRoot, 'analysis_options.yaml');
    if (!File(analysisOptionsPath).existsSync()) {
      final expLines = config.enabledExperiments
          .map((e) => '    - $e')
          .join('\n');
      provider.setOverlay(
        analysisOptionsPath,
        content:
            'analyzer:\n'
            '  enable-experiment:\n'
            '$expLines\n',
        modificationStamp: stamp++,
      );
    }

    final collection = AnalysisContextCollection(
      includedPaths: [absContextRoot],
      resourceProvider: provider,
    );
    final context = collection.contextFor(absContextRoot);

    var totalBlocks = 0;
    var skippedBlocks = 0;
    var verifiedExpectedErrors = 0;
    final diagnostics = <MarkdownDiagnostic>[];
    final stagedForLinter =
        <
          ({
            MarkdownCodeBlock block,
            String mode,
            String fullSource,
            int bodyStartOffset,
            int bodyEndOffset,
          })
        >[];

    for (final file in markdownFiles) {
      final relPath = p.posix.joinAll(
        p.split(p.relative(file.path, from: absMdRoot)),
      );
      final mdContent = file.readAsStringSync();
      final blocks = extractMarkdownDartBlocks(relPath, mdContent);
      if (blocks.isEmpty) continue;

      final fileImports = <String>{...config.ambientImports};
      final fileDecls = <String, String>{};
      final persistentFileOverlays = <String>[];

      try {
        for (final block in blocks) {
          totalBlocks++;
          if (block.isSkipped) {
            skippedBlocks++;
            continue;
          }

          var cand = wrapAndParseSnippet(block.code, featureSet: featureSet);
          if (!cand.passed && config.allowEllipsis) {
            cand = wrapAndParseSnippet(
              block.code,
              featureSet: featureSet,
              allowEllipsis: true,
            );
          }

          if (!cand.passed) {
            for (final err in cand.syntaxErrors) {
              final code = err.errorCode.name.toLowerCase();
              final sev = config.effectiveSeverity(
                code,
                MarkdownDiagnosticSeverity.error,
              );
              if (sev != MarkdownDiagnosticSeverity.ignore) {
                diagnostics.add(
                  MarkdownDiagnostic(
                    block: block,
                    code: code,
                    severity: sev,
                    message: err.message,
                    wrappingMode: cand.mode,
                  ),
                );
              }
            }
            continue;
          }

          final subChunks = splitContrastSubSnippets(
            block.code,
            featureSet: featureSet,
            allowEllipsis: config.allowEllipsis,
          );
          final blockDiagnostics = <MarkdownDiagnostic>[];

          for (final subCode in subChunks) {
            var subCand = wrapAndParseSnippet(subCode, featureSet: featureSet);
            if (!subCand.passed && config.allowEllipsis) {
              subCand = wrapAndParseSnippet(
                subCode,
                featureSet: featureSet,
                allowEllipsis: true,
              );
            }

            final pathHint = extractSnippetPathHint(subCode);
            final overlayPath = pathHint != null
                ? p.join(absContextRoot, pathHint)
                : p.join(absContextRoot, 'test', '__snippet_${stamp++}.dart');

            final (newImports, newDecls) = extractTopLevelContext(
              subCode,
              featureSet: featureSet,
            );
            final currentDeclaredNames = extractDeclaredIdentifierNames(
              subCand.wrappedCode,
              featureSet: featureSet,
            );

            final combinedImports = <String>{
              if (pathHint == null) ...fileImports,
              ...newImports,
            };

            final wrappedLines = const LineSplitter().convert(
              subCand.wrappedCode,
            );
            final bodyWithoutImports = <String>[];
            var hasLibraryOrAnnotationBeforeImports = false;
            for (final l in wrappedLines) {
              final t = l.trim();
              if (t.startsWith('import ') && t.endsWith(';')) {
                combinedImports.add(t);
              } else {
                if (t.startsWith('@Tags(') ||
                    t.startsWith('@TestOn(') ||
                    t.startsWith('@Timeout(') ||
                    t.startsWith('library')) {
                  hasLibraryOrAnnotationBeforeImports = true;
                }
                bodyWithoutImports.add(l);
              }
            }

            final priorDecls = <String>[
              if (pathHint == null)
                for (final entry in fileDecls.entries)
                  if (!currentDeclaredNames.contains(entry.key)) entry.value,
            ];

            final bodyText = bodyWithoutImports.join('\n');
            final String fullSource;
            final int bodyStartOffset;
            final int bodyEndOffset;
            if (hasLibraryOrAnnotationBeforeImports) {
              bodyStartOffset = 0;
              bodyEndOffset = bodyText.length;
              fullSource = [
                bodyText,
                ...combinedImports,
                ...priorDecls,
              ].join('\n');
            } else {
              final prefix = [...combinedImports, ...priorDecls].join('\n');
              bodyStartOffset = prefix.isEmpty ? 0 : prefix.length + 1;
              bodyEndOffset = bodyStartOffset + bodyText.length;
              fullSource = prefix.isEmpty ? bodyText : '$prefix\n$bodyText';
            }

            fileImports.addAll(newImports);
            fileDecls.addAll(newDecls);

            if (config.shouldRunLinter &&
                !block.isAntiPatternExample &&
                !block.isExpectedErrorExample) {
              stagedForLinter.add((
                block: block,
                mode: subCand.mode,
                fullSource: fullSource,
                bodyStartOffset: bodyStartOffset,
                bodyEndOffset: bodyEndOffset,
              ));
            }

            provider.setOverlay(
              overlayPath,
              content: fullSource,
              modificationStamp: stamp++,
            );
            if (pathHint != null) {
              persistentFileOverlays.add(overlayPath);
            }

            try {
              context.changeFile(overlayPath);
              await context.applyPendingFileChanges();
              final errorsResult = await context.currentSession.getErrors(
                overlayPath,
              );
              if (errorsResult is ErrorsResult) {
                final inRangeErrors = errorsResult.errors.where(
                  (e) =>
                      e.offset >= bodyStartOffset && e.offset <= bodyEndOffset,
                );
                final hasUnboundPlaceholders = inRangeErrors.any(
                  (e) => placeholderSymbolDiagnosticCodes.contains(
                    e.errorCode.name.toLowerCase(),
                  ),
                );
                final hasExtendsNonClass = inRangeErrors.any(
                  (e) => e.errorCode.name.toLowerCase() == 'extends_non_class',
                );

                for (final err in inRangeErrors) {
                  final code = err.errorCode.name.toLowerCase();
                  final defaultSev = _mapAnalyzerSeverity(err.severity.name);
                  final effectiveSev = config.effectiveSeverity(
                    code,
                    defaultSev,
                  );
                  if (effectiveSev == MarkdownDiagnosticSeverity.ignore) {
                    continue;
                  }

                  final explicitlyOverridden = config.severityOverrides
                      .containsKey(code);
                  if (!explicitlyOverridden &&
                      config.ignoreUnboundPlaceholders) {
                    if (placeholderSymbolDiagnosticCodes.contains(code)) {
                      continue;
                    }
                    if (subCand.mode == 'class-member' &&
                        code == 'override_on_non_overriding_member') {
                      continue;
                    }
                    if (hasUnboundPlaceholders &&
                        cascadingUnboundDiagnosticCodes.contains(code)) {
                      continue;
                    }
                    if (hasExtendsNonClass &&
                        cascadingUnresolvedSuperclassCodes.contains(code)) {
                      continue;
                    }
                    if (err.message.contains('InvalidType')) {
                      continue;
                    }
                    if (code == 'inference_failure_on_untyped_parameter' ||
                        code == 'inference_failure_on_function_return_type' ||
                        code == 'inference_failure_on_collection_literal' ||
                        code == 'inference_failure_on_instance_creation' ||
                        code == 'strict_raw_type') {
                      continue;
                    }
                  }

                  blockDiagnostics.add(
                    MarkdownDiagnostic(
                      block: block,
                      code: code,
                      severity: effectiveSev,
                      message: err.message,
                      wrappingMode: subCand.mode,
                      pathHint: pathHint,
                    ),
                  );
                }
              }
            } finally {
              if (pathHint == null) {
                provider.removeOverlay(overlayPath);
                context.changeFile(overlayPath);
              }
            }
          }

          if (blockDiagnostics.isNotEmpty) {
            if (block.isExpectedErrorExample) {
              verifiedExpectedErrors++;
            } else {
              diagnostics.addAll(blockDiagnostics);
            }
          }
        }
      } finally {
        for (final pPath in persistentFileOverlays) {
          provider.removeOverlay(pPath);
          context.changeFile(pPath);
        }
      }
    }

    if (config.shouldRunLinter && stagedForLinter.isNotEmpty) {
      final lintDiagnostics = _runBatchSdkLinter(
        stagedSnippets: stagedForLinter,
        mergedConfigJson: mergedConfigJson,
        config: config,
      );
      diagnostics.addAll(lintDiagnostics);
    }

    return MarkdownAnalysisResult(
      totalBlocks: totalBlocks,
      skippedBlocks: skippedBlocks,
      verifiedExpectedErrorBlocks: verifiedExpectedErrors,
      diagnostics: diagnostics,
    );
  }
}

List<MarkdownDiagnostic> _runBatchSdkLinter({
  required List<
    ({
      MarkdownCodeBlock block,
      String mode,
      String fullSource,
      int bodyStartOffset,
      int bodyEndOffset,
    })
  >
  stagedSnippets,
  required String? mergedConfigJson,
  required MarkdownAnalyzeConfig config,
}) {
  final tempDir = Directory.systemTemp.createTempSync('md_analyze_lint_');
  try {
    if (mergedConfigJson != null) {
      final dotDartTool = Directory(p.join(tempDir.path, '.dart_tool'))
        ..createSync();
      File(
        p.join(dotDartTool.path, 'package_config.json'),
      ).writeAsStringSync(mergedConfigJson);
    }
    File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync(
      'name: _standalone_markdown_target\n'
      'environment:\n'
      '  sdk: ^${config.sdkLanguageVersion}\n',
    );

    final expLines = config.enabledExperiments
        .map((e) => '    - $e')
        .join('\n');
    final ruleMap = <String, bool>{
      for (final r in config.enabledLints) r.toLowerCase(): true,
      for (final r in config.disabledLints) r.toLowerCase(): false,
    };
    final ruleLines = ruleMap.entries
        .map((e) => '    ${e.key}: ${e.value}')
        .join('\n');
    final includeLine = config.includeRecommendedLints
        ? 'include: package:lints/recommended.yaml\n'
        : '';
    File(p.join(tempDir.path, 'analysis_options.yaml')).writeAsStringSync(
      '$includeLine'
      'analyzer:\n'
      '  enable-experiment:\n'
      '$expLines\n'
      'linter:\n'
      '  rules:\n'
      '$ruleLines\n',
    );

    final byFileName =
        <
          String,
          ({
            MarkdownCodeBlock block,
            String mode,
            String fullSource,
            int bodyStartOffset,
            int bodyEndOffset,
          })
        >{};
    for (var i = 0; i < stagedSnippets.length; i++) {
      final fileName = 'snippet_$i.dart';
      final item = stagedSnippets[i];
      File(p.join(tempDir.path, fileName)).writeAsStringSync(item.fullSource);
      byFileName[fileName] = item;
    }

    final proc = Process.runSync('dart', [
      'analyze',
      '--format=json',
      tempDir.path,
    ]);
    final results = <MarkdownDiagnostic>[];
    final outLines = const LineSplitter().convert(proc.stdout as String);
    for (final line in outLines) {
      if (!line.startsWith('{')) continue;
      final json = jsonDecode(line) as Map<String, Object?>;
      final rawList = (json['diagnostics'] as List<Object?>?) ?? const [];
      for (final d in rawList.whereType<Map<String, Object?>>()) {
        final type = d['type'] as String? ?? '';
        if (type != 'LINT') continue;
        final code = (d['code'] as String? ?? '').toLowerCase();
        if (config.disabledLints.contains(code)) continue;
        final loc = d['location'] as Map<String, Object?>?;
        final fileName = p.basename(loc?['file'] as String? ?? '');
        final staged = byFileName[fileName];
        if (staged == null) continue;
        final range = loc?['range'] as Map<String, Object?>?;
        final start = range?['start'] as Map<String, Object?>?;
        final offset = start?['offset'] as int? ?? 0;
        if (offset < staged.bodyStartOffset || offset > staged.bodyEndOffset) {
          continue;
        }
        final rawSev = _mapAnalyzerSeverity(d['severity'] as String? ?? 'info');
        final effectiveSev = config.effectiveSeverity(code, rawSev);
        if (effectiveSev == MarkdownDiagnosticSeverity.ignore) continue;
        results.add(
          MarkdownDiagnostic(
            block: staged.block,
            code: code,
            severity: effectiveSev,
            message: d['problemMessage'] as String? ?? code,
            wrappingMode: staged.mode,
          ),
        );
      }
    }
    return results;
  } finally {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  }
}

MarkdownDiagnosticSeverity _mapAnalyzerSeverity(String severityName) {
  return switch (severityName.toLowerCase()) {
    'error' => MarkdownDiagnosticSeverity.error,
    'warning' => MarkdownDiagnosticSeverity.warning,
    _ => MarkdownDiagnosticSeverity.info,
  };
}

List<Map<String, Object?>> _loadNormalizedPackages(String configFilePath) {
  final file = File(configFilePath);
  if (!file.existsSync()) return const [];
  final jsonMap = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  final packages = (jsonMap['packages'] as List<Object?>?) ?? const [];
  final configDirUri = Uri.directory(p.dirname(p.absolute(configFilePath)));
  final result = <Map<String, Object?>>[];
  for (final entry in packages.whereType<Map<String, Object?>>()) {
    final copy = Map<String, Object?>.of(entry);
    final rootUriStr = copy['rootUri'] as String?;
    if (rootUriStr != null && !rootUriStr.startsWith('file:')) {
      final resolved = configDirUri.resolve(rootUriStr);
      copy['rootUri'] = resolved.toString();
    }
    result.add(copy);
  }
  return result;
}

/// Builds a merged `package_config.json` combining [targetRoot]'s workspace
/// packages (if any) with [fallbackPackageConfigPath]'s packages.
String? buildMergedPackageConfigJson({
  required String targetRoot,
  String? fallbackPackageConfigPath,
}) {
  final byName = <String, Map<String, Object?>>{};

  if (fallbackPackageConfigPath != null) {
    for (final pkg in _loadNormalizedPackages(fallbackPackageConfigPath)) {
      final name = pkg['name'] as String?;
      if (name != null) {
        byName[name] = pkg;
      }
    }
  }

  var foundTargetConfig = false;
  var dir = p.absolute(targetRoot);
  for (var i = 0; i < 3; i++) {
    final candidate = p.join(dir, '.dart_tool', 'package_config.json');
    if (File(candidate).existsSync()) {
      foundTargetConfig = true;
      for (final pkg in _loadNormalizedPackages(candidate)) {
        final name = pkg['name'] as String?;
        if (name != null) {
          byName[name] = pkg;
        }
      }
      break;
    }
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }

  if (!foundTargetConfig && byName.isEmpty) {
    return null;
  }

  if (!File(p.join(targetRoot, 'pubspec.yaml')).existsSync()) {
    byName.putIfAbsent(
      '_standalone_markdown_target',
      () => <String, Object?>{
        'name': '_standalone_markdown_target',
        'rootUri': Uri.directory(p.absolute(targetRoot)).toString(),
        'packageUri': 'lib/',
        'languageVersion': '3.12',
      },
    );
  }

  final merged = <String, Object?>{
    'configVersion': 2,
    'packages': byName.values.toList(),
  };
  return const JsonEncoder.withIndent('  ').convert(merged);
}
