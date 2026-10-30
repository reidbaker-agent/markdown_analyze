// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:markdown_analyze/markdown_analyze.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption(
      'context-root',
      abbr: 'c',
      help: 'Dart package/workspace root directory used for analysis context.',
    )
    ..addOption(
      'fallback-package-config',
      help:
          'Fallback .dart_tool/package_config.json path for standalone repos.',
    )
    ..addMultiOption(
      'ambient-import',
      help: 'Additional ambient import statement injected into snippets.',
    )
    ..addMultiOption('ignore-diagnostic', help: 'Diagnostic code(s) to ignore.')
    ..addMultiOption(
      'error-diagnostic',
      help: 'Diagnostic code(s) to promote/enable as errors.',
    )
    ..addFlag('json', negatable: false, help: 'Emit diagnostics as JSON.')
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show usage information.',
    );

  final ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln('Error: ${e.message}');
    stderr.writeln(parser.usage);
    exit(64);
  }

  if (parsed['help'] as bool) {
    stdout.writeln(
      'Usage: markdown_analyze [options] [<markdown-directory-or-file>]',
    );
    stdout.writeln(parser.usage);
    return;
  }

  final targetPath = parsed.rest.isNotEmpty
      ? p.normalize(p.absolute(parsed.rest.first))
      : Directory.current.path;
  final contextRoot =
      parsed['context-root'] as String? ??
      (FileSystemEntity.isFileSync(targetPath)
          ? p.dirname(targetPath)
          : targetPath);

  final severityOverrides = <String, MarkdownDiagnosticSeverity>{
    for (final code in parsed['ignore-diagnostic'] as List<String>)
      code.toLowerCase(): MarkdownDiagnosticSeverity.ignore,
    for (final code in parsed['error-diagnostic'] as List<String>)
      code.toLowerCase(): MarkdownDiagnosticSeverity.error,
  };

  const baseConfig = MarkdownAnalyzeConfig();
  final analyzer = MarkdownDartAnalyzer(
    config: MarkdownAnalyzeConfig(
      ambientImports: [
        ...baseConfig.ambientImports,
        ...(parsed['ambient-import'] as List<String>),
      ],
      severityOverrides: severityOverrides,
      fallbackPackageConfigPath: parsed['fallback-package-config'] as String?,
    ),
  );

  final MarkdownAnalysisResult result;
  if (FileSystemEntity.isFileSync(targetPath)) {
    result = await analyzer.analyzeFiles(
      contextRoot: contextRoot,
      markdownRoot: p.dirname(targetPath),
      markdownFiles: [File(targetPath)],
    );
  } else {
    result = await analyzer.analyzeDirectory(
      contextRoot: contextRoot,
      markdownRoot: targetPath,
    );
  }

  if (parsed['json'] as bool) {
    final payload = <String, Object?>{
      'totalBlocks': result.totalBlocks,
      'skippedBlocks': result.skippedBlocks,
      'verifiedExpectedErrorBlocks': result.verifiedExpectedErrorBlocks,
      'diagnostics': [
        for (final d in result.diagnostics)
          <String, Object?>{
            'file': d.block.filePath,
            'startLine': d.block.startLine,
            'endLine': d.block.endLine,
            'code': d.code,
            'severity': d.severity.name,
            'message': d.message,
            'wrappingMode': d.wrappingMode,
            if (d.pathHint != null) 'pathHint': d.pathHint,
          },
      ],
    };
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(payload));
  } else {
    for (final d in result.diagnostics) {
      stdout.writeln(d.describe());
    }
    stdout.writeln(
      'Analyzed ${result.totalBlocks} Dart block(s) '
      '(${result.diagnostics.length} diagnostic(s), '
      '${result.verifiedExpectedErrorBlocks} verified expected-error block(s), '
      '${result.skippedBlocks} skipped).',
    );
  }

  if (result.hasErrors) {
    exit(1);
  }
}
