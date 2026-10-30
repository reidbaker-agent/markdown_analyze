// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:meta/meta.dart';

/// Severity level for a diagnostic or consumer severity override.
enum MarkdownDiagnosticSeverity { ignore, info, warning, error }

/// A fenced `dart` code block extracted from a Markdown document.
@immutable
class MarkdownCodeBlock {
  const MarkdownCodeBlock({
    required this.filePath,
    required this.startLine,
    required this.endLine,
    required this.infoString,
    required this.code,
    this.isExpectedErrorExample = false,
    this.isAntiPatternExample = false,
  });

  /// Relative or display path of the Markdown file.
  final String filePath;

  /// 1-based line number of the first code line inside the fence.
  final int startLine;

  /// 1-based line number of the last code line inside the fence.
  final int endLine;

  /// Raw fence info string (e.g. `dart`, `dart no-analyze`).
  final String infoString;

  /// Raw Dart source text inside the fence.
  final String code;

  /// Whether the block or its surrounding Markdown explicitly marks it as an
  /// intentional compile/static-analysis error demonstration.
  final bool isExpectedErrorExample;

  /// Whether the surrounding Markdown marks the block as a style anti-pattern
  /// (e.g. `**Avoid:**`, `Bad:`).
  final bool isAntiPatternExample;

  /// Whether the fence info string opts out of analysis (e.g. `no-analyze`,
  /// `ignore`, `#no-test`).
  bool get isSkipped =>
      infoString.contains('no-analyze') ||
      infoString.contains('no-test') ||
      infoString.contains('ignore');

  String get location => '$filePath:$startLine-$endLine';
}

/// A diagnostic reported on a [MarkdownCodeBlock].
@immutable
class MarkdownDiagnostic {
  const MarkdownDiagnostic({
    required this.block,
    required this.code,
    required this.severity,
    required this.message,
    required this.wrappingMode,
    this.pathHint,
  });

  final MarkdownCodeBlock block;
  final String code;
  final MarkdownDiagnosticSeverity severity;
  final String message;
  final String wrappingMode;
  final String? pathHint;

  String describe() =>
      '${block.location} [${severity.name}/$code] $message (mode=$wrappingMode'
      '${pathHint != null ? ', path=$pathHint' : ''})';
}

/// Result of analyzing all Markdown files in a target root or list of files.
@immutable
class MarkdownAnalysisResult {
  const MarkdownAnalysisResult({
    required this.totalBlocks,
    required this.skippedBlocks,
    required this.verifiedExpectedErrorBlocks,
    required this.diagnostics,
  });

  final int totalBlocks;
  final int skippedBlocks;
  final int verifiedExpectedErrorBlocks;
  final List<MarkdownDiagnostic> diagnostics;

  bool get hasErrors => diagnostics.isNotEmpty;
}

/// Consumer configuration for analyzing and linting Dart code in Markdown.
///
/// Consumers can customize diagnostic severities ([severityOverrides]),
/// enabled/disabled lints, ambient imports, and fallback package resolution
/// while inheriting sensible defaults for sample code (such as ignoring
/// `unused_local_variable`, `unused_element`, `unused_import`, and `avoid_print`).
@immutable
class MarkdownAnalyzeConfig {
  const MarkdownAnalyzeConfig({
    this.sdkLanguageVersion = '3.12.0',
    this.enabledExperiments = const [
      'primary-constructors',
      'dot-shorthands',
      'enhanced-parts',
    ],
    this.ambientImports = const [
      "import 'dart:async';",
      "import 'dart:io';",
      "import 'dart:math' as math;",
      "import 'package:path/path.dart' as p;",
      "import 'package:path/path.dart' as path;",
      "import 'package:test/test.dart';",
    ],
    this.severityOverrides = const {},
    this.includeRecommendedLints = false,
    this.enabledLints = const {},
    this.disabledLints = const {},
    this.allowEllipsis = true,
    this.ignoreUnboundPlaceholders = true,
    this.fallbackPackageConfigPath,
    this.excludedPathSegments = const {'.dart_tool', '.git', 'third_party'},
  });

  /// Default sample-friendly ignored diagnostic codes (lowercase).
  ///
  /// Sample snippets in Markdown routinely declare illustrative variables,
  /// imports, helper functions, or `print` calls without consuming them.
  static const Set<String> defaultSampleIgnoredCodes = {
    'unused_import',
    'unused_local_variable',
    'unused_element',
    'unused_field',
    'avoid_print',
    'prefer_const_constructors',
    'unreachable_from_main',
    'dangling_library_doc_comments',
    'depend_on_referenced_packages',
    'no_leading_underscores_for_local_identifiers',
  };

  /// Dart language version used for parsing and synthetic package configs.
  final String sdkLanguageVersion;

  /// Experimental Dart language flags enabled during parsing and analysis.
  final List<String> enabledExperiments;

  /// Ambient imports injected into snippets that do not specify an explicit
  /// repo file path hint.
  final List<String> ambientImports;

  /// Consumer overrides mapping diagnostic/lint codes (lowercase) to
  /// [MarkdownDiagnosticSeverity].
  ///
  /// Setting a code in [defaultSampleIgnoredCodes] to
  /// [MarkdownDiagnosticSeverity.warning] or [MarkdownDiagnosticSeverity.error]
  /// re-enables that diagnostic for the consumer. Setting any analyzer code to
  /// [MarkdownDiagnosticSeverity.ignore] suppresses it.
  final Map<String, MarkdownDiagnosticSeverity> severityOverrides;

  /// Whether to include `package:lints/recommended.yaml` and run the SDK
  /// `dart analyze` linter pass on extracted snippets.
  final bool includeRecommendedLints;

  /// Explicit lint rules enabled by the consumer for the SDK `dart analyze`
  /// linter pass (e.g. `{'use_raw_strings', 'library_annotations'}`).
  final Set<String> enabledLints;

  /// Lint rules explicitly disabled by the consumer.
  final Set<String> disabledLints;

  /// Whether the SDK `dart analyze` linter pass should run.
  bool get shouldRunLinter =>
      includeRecommendedLints || enabledLints.isNotEmpty;

  /// Whether to sanitize `...` placeholders in code snippets when strict
  /// parsing fails.
  final bool allowEllipsis;

  /// Whether to ignore unresolved placeholder identifiers (`undefined_class`,
  /// `undefined_function`, `undefined_unqualified_name_read`, etc.) and their
  /// cascading `InvalidType` diagnostics in snippets that reference
  /// illustrative symbols not defined in the file.
  final bool ignoreUnboundPlaceholders;

  /// Optional path to a fallback `.dart_tool/package_config.json` whose
  /// resolved packages are merged into the in-memory overlay so standalone
  /// Markdown repositories (without a `pubspec.yaml`) and skills referencing
  /// external packages (`package:checks`, `package:http`, etc.) resolve.
  final String? fallbackPackageConfigPath;

  /// Directory names excluded when recursively scanning for `.md` files.
  final Set<String> excludedPathSegments;

  /// Resolves the effective severity of [code] given its analyzer default
  /// [defaultSeverity] and consumer [severityOverrides].
  MarkdownDiagnosticSeverity effectiveSeverity(
    String code,
    MarkdownDiagnosticSeverity defaultSeverity,
  ) {
    final normalized = code.toLowerCase();
    final override = severityOverrides[normalized];
    if (override != null) {
      return override;
    }
    if (defaultSampleIgnoredCodes.contains(normalized)) {
      return MarkdownDiagnosticSeverity.ignore;
    }
    return defaultSeverity;
  }
}
