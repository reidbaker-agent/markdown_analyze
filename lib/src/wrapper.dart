// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/error/error.dart';
import 'package:pub_semver/pub_semver.dart';

/// Result of wrapping and syntax-checking a Markdown Dart snippet.
class WrappedSnippet {
  WrappedSnippet({
    required this.mode,
    required this.wrappedCode,
    required this.syntaxErrors,
    required this.usedEllipsis,
  });

  final String mode;
  final String wrappedCode;
  final List<AnalysisError> syntaxErrors;
  final bool usedEllipsis;

  bool get passed => syntaxErrors.isEmpty;
}

/// Builds a [FeatureSet] for the given SDK version and experimental flags.
FeatureSet buildSnippetFeatureSet({
  String sdkLanguageVersion = '3.12.0',
  List<String> enabledExperiments = const [
    'primary-constructors',
    'dot-shorthands',
    'enhanced-parts',
  ],
}) {
  return FeatureSet.fromEnableFlags2(
    sdkLanguageVersion: Version.parse(sdkLanguageVersion),
    flags: enabledExperiments,
  );
}

/// Replaces common documentation ellipsis idioms (`=> ...;`, `{ ... }`, `(...)`,
/// standalone `...` lines, or truncated class declarations ending after `;`)
/// with valid Dart placeholders.
String sanitizeSnippetEllipsis(String code) {
  var sanitized = code
      .replaceAllMapped(
        RegExp(
          r'\b((?:class|mixin|enum|extension)\s+[^{]+)\{\s*\.\.\.\s*\}',
          multiLine: true,
        ),
        (m) => '${m.group(1)}{}',
      )
      .replaceAll('=> ...;', '=> throw UnimplementedError();')
      .replaceAll('{ ... }', '{ throw UnimplementedError(); }')
      .replaceAll('{...}', '{ throw UnimplementedError(); }')
      .replaceAll('(it) => ...)', '(it) {})')
      .replaceAll('(...)', '()')
      .replaceAll(RegExp(r'^\s*\.\.\.\s*$', multiLine: true), '// ...');

  final openBraces = '{'.allMatches(sanitized).length;
  final closeBraces = '}'.allMatches(sanitized).length;
  if (openBraces > closeBraces && sanitized.trimRight().endsWith(';')) {
    final missing = '}' * (openBraces - closeBraces);
    sanitized = '$sanitized\n$missing';
  }
  return sanitized;
}

/// Attempts to parse [rawCode] across candidate wrapping templates (`unit`,
/// `main-body`, `expression`, `collection-element`, `class-member`,
/// `imports+main-body`, `named-ctor-class`).
WrappedSnippet wrapAndParseSnippet(
  String rawCode, {
  required FeatureSet featureSet,
  bool allowEllipsis = false,
}) {
  final source = allowEllipsis ? sanitizeSnippetEllipsis(rawCode) : rawCode;

  final lines = const LineSplitter().convert(source);
  final importLines = <String>[];
  final bodyLines = <String>[];
  var inHeader = true;
  for (final line in lines) {
    final t = line.trim();
    if (inHeader &&
        (t.isEmpty ||
            t.startsWith('//') ||
            t.startsWith('///') ||
            t.startsWith('import ') ||
            t.startsWith('export ') ||
            t.startsWith('library'))) {
      importLines.add(line);
    } else {
      inHeader = false;
      bodyLines.add(line);
    }
  }

  final hasTopLevelOverride =
      RegExp(r'^\s*@override\b', multiLine: true).hasMatch(source) &&
      !RegExp(
        r'\b(class|enum|mixin|extension)\s+[A-Za-z0-9_]+',
      ).hasMatch(source);

  final candidates = <(String mode, String code)>[
    if (hasTopLevelOverride)
      ('class-member', 'abstract class _SnippetHost {\n$source\n}\n'),
    if (!hasTopLevelOverride) ('unit', source),
    (
      'main-body',
      'Future<Object?> _snippetMain() async {\n$source\nreturn null;\n}\n',
    ),
    ('expression', 'Object? _snippetExpr() =>\n$source\n;\n'),
    ('collection-element', 'final _snippetList = [\n$source\n];\n'),
    if (!hasTopLevelOverride)
      ('class-member', 'abstract class _SnippetHost {\n$source\n}\n'),
    if (hasTopLevelOverride) ('unit', source),
    if (importLines.isNotEmpty && bodyLines.isNotEmpty)
      (
        'imports+main-body',
        '${importLines.join('\n')}\nFuture<Object?> _snippetMain() async {\n${bodyLines.join('\n')}\nreturn null;\n}\n',
      ),
  ];

  final namedCtorMatch = RegExp(
    r'^\s*(?:\/\/\/.*\n|\s*)*([A-Z][A-Za-z0-9_]*)\.[a-zA-Z0-9_]+\s*\(',
  ).firstMatch(source);
  if (namedCtorMatch != null) {
    final className = namedCtorMatch.group(1)!;
    candidates.add(('named-ctor-class', 'class $className {\n$source\n}\n'));
  }

  List<AnalysisError>? bestErrors;
  var bestMode = 'unit';
  var bestWrapped = source;

  for (final (mode, code) in candidates) {
    final errors = parseString(
      content: code,
      featureSet: featureSet,
      throwIfDiagnostics: false,
    ).errors;
    if (errors.isEmpty) {
      return WrappedSnippet(
        mode: mode,
        wrappedCode: code,
        syntaxErrors: const [],
        usedEllipsis: allowEllipsis,
      );
    }
    if (bestErrors == null || errors.length < bestErrors.length) {
      bestErrors = errors;
      bestMode = mode;
      bestWrapped = code;
    }
  }

  return WrappedSnippet(
    mode: bestMode,
    wrappedCode: bestWrapped,
    syntaxErrors: bestErrors ?? const [],
    usedEllipsis: allowEllipsis,
  );
}

/// Splits a code block into contrast sub-blocks (e.g. `// Before` vs `// After`,
/// `// Bad` vs `// Good`) when each section parses cleanly as a standalone snippet.
List<String> splitContrastSubSnippets(
  String code, {
  required FeatureSet featureSet,
  bool allowEllipsis = true,
}) {
  final lines = const LineSplitter().convert(code);
  final splitIndices = <int>[];
  final markerRe = RegExp(
    r'^\s*//\s*(Good|After|Prefer|YES|Correct)\b',
    caseSensitive: false,
  );
  for (var i = 1; i < lines.length; i++) {
    if (markerRe.hasMatch(lines[i])) {
      splitIndices.add(i);
    }
  }
  if (splitIndices.isEmpty) return [code];

  final chunks = <String>[];
  var start = 0;
  for (final idx in splitIndices) {
    final chunk = lines.sublist(start, idx).join('\n').trim();
    if (chunk.isNotEmpty) chunks.add(chunk);
    start = idx;
  }
  final lastChunk = lines.sublist(start).join('\n').trim();
  if (lastChunk.isNotEmpty) chunks.add(lastChunk);

  if (chunks.length <= 1) return [code];
  for (final c in chunks) {
    var cand = wrapAndParseSnippet(c, featureSet: featureSet);
    if (!cand.passed && allowEllipsis) {
      cand = wrapAndParseSnippet(
        c,
        featureSet: featureSet,
        allowEllipsis: true,
      );
    }
    if (!cand.passed) return [code];
  }
  return chunks;
}

String? declarationName(CompilationUnitMember decl) {
  return switch (decl) {
    final FunctionDeclaration d => d.name.lexeme,
    final ClassDeclaration d => d.namePart.typeName.lexeme,
    final EnumDeclaration d => d.namePart.typeName.lexeme,
    final MixinDeclaration d => d.name.lexeme,
    final ExtensionDeclaration d => d.name?.lexeme,
    final ExtensionTypeDeclaration d => d.primaryConstructor.typeName.lexeme,
    final GenericTypeAlias d => d.name.lexeme,
    final FunctionTypeAlias d => d.name.lexeme,
    final TopLevelVariableDeclaration d =>
      d.variables.variables.isNotEmpty
          ? d.variables.variables.first.name.lexeme
          : null,
    _ => null,
  };
}

/// Extracts top-level imports and named declarations from a valid compilation
/// unit so subsequent blocks in the same Markdown file can build on earlier
/// declarations without colliding on redefined names.
(List<String> imports, Map<String, String> namedDecls) extractTopLevelContext(
  String code, {
  required FeatureSet featureSet,
}) {
  final res = parseString(
    content: code,
    featureSet: featureSet,
    throwIfDiagnostics: false,
  );
  if (res.errors.isNotEmpty) return (const [], const {});
  final imports = <String>[];
  final decls = <String, String>{};
  for (final d in res.unit.directives) {
    if (d is ImportDirective) {
      imports.add(code.substring(d.offset, d.end));
    }
  }
  for (final decl in res.unit.declarations) {
    final name = declarationName(decl);
    if (name == null || name == 'main' || name.startsWith('_snippet')) {
      continue;
    }
    decls[name] = code.substring(decl.offset, decl.end);
  }
  return (imports, decls);
}

/// Returns all declared identifier names in a wrapped snippet so earlier
/// top-level declarations of the same name are not re-injected.
Set<String> extractDeclaredIdentifierNames(
  String wrappedCode, {
  required FeatureSet featureSet,
}) {
  final res = parseString(
    content: wrappedCode,
    featureSet: featureSet,
    throwIfDiagnostics: false,
  );
  final names = <String>{};
  for (final decl in res.unit.declarations) {
    final name = declarationName(decl);
    if (name != null) names.add(name);
    if (decl is FunctionDeclaration && decl.name.lexeme == '_snippetMain') {
      final body = decl.functionExpression.body;
      if (body is BlockFunctionBody) {
        for (final stmt in body.block.statements) {
          if (stmt is VariableDeclarationStatement) {
            for (final v in stmt.variables.variables) {
              names.add(v.name.lexeme);
            }
          } else if (stmt is FunctionDeclarationStatement) {
            names.add(stmt.functionDeclaration.name.lexeme);
          }
        }
      }
    }
  }
  return names;
}

/// Extracts a leading file path comment such as `// lib/src/rules/my_new_rule.dart`
/// if present in the first 3 lines of [code].
String? extractSnippetPathHint(String code) {
  for (final line in const LineSplitter().convert(code).take(3)) {
    final m = RegExp(
      r'^\s*//\s*((?:lib|test|bin|example)/[A-Za-z0-9_./-]+\.dart)\s*$',
    ).firstMatch(line);
    if (m != null) {
      return m.group(1);
    }
  }
  return null;
}
