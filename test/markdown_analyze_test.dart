// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:markdown_analyze/markdown_analyze.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final fallbackConfigPath = p.normalize(
    p.absolute('.dart_tool/package_config.json'),
  );

  group('Extractor & Wrapper', () {
    test('ignores nested ```dart fences inside outer ````markdown blocks', () {
      const md = '''
````markdown
```dart
final broken = ";
```
````

```dart
final valid = 42;
```
''';
      final blocks = extractMarkdownDartBlocks('README.md', md);
      expect(blocks, hasLength(1));
      expect(blocks.single.code, 'final valid = 42;');
    });

    test(
      'wraps standalone @override method as class-member before main-body',
      () {
        const snippet = '''
  @override
  String toString() => 'custom';
''';
        final featureSet = buildSnippetFeatureSet();
        final wrapped = wrapAndParseSnippet(snippet, featureSet: featureSet);
        expect(wrapped.passed, isTrue);
        expect(wrapped.mode, 'class-member');
      },
    );

    test(
      'splits // Before and // After blocks to prevent class self-shadowing',
      () {
        const snippet = '''
// Before
class DatabaseService {
  final String url;
  DatabaseService(this.url);
  factory DatabaseService.create() => DatabaseService('default');
}

// After
class DatabaseService {
  final String url;
  new(this.url);
  factory create() => DatabaseService('default');
}
''';
        final featureSet = buildSnippetFeatureSet();
        final chunks = splitContrastSubSnippets(
          snippet,
          featureSet: featureSet,
        );
        expect(chunks, hasLength(2));
      },
    );
  });

  group('Consumer-Configurable Severities & Sample Defaults', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('md_analyze_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'tolerates unused_local_variable by default but flags it when consumer overrides',
      () async {
        final mdFile = File(p.join(tempDir.path, 'SKILL.md'))
          ..writeAsStringSync('''
```dart
void main() {
  final unusedSampleVar = 123;
}
```
''');

        // 1. Default sample config ignores unused_local_variable
        final defaultAnalyzer = MarkdownDartAnalyzer(
          config: MarkdownAnalyzeConfig(
            fallbackPackageConfigPath: fallbackConfigPath,
          ),
        );
        final defaultRes = await defaultAnalyzer.analyzeFiles(
          contextRoot: tempDir.path,
          markdownRoot: tempDir.path,
          markdownFiles: [mdFile],
        );
        expect(defaultRes.diagnostics, isEmpty);

        // 2. Consumer config overriding unused_local_variable to error reports it
        final strictAnalyzer = MarkdownDartAnalyzer(
          config: MarkdownAnalyzeConfig(
            fallbackPackageConfigPath: fallbackConfigPath,
            severityOverrides: const {
              'unused_local_variable': MarkdownDiagnosticSeverity.error,
            },
          ),
        );
        final strictRes = await strictAnalyzer.analyzeFiles(
          contextRoot: tempDir.path,
          markdownRoot: tempDir.path,
          markdownFiles: [mdFile],
        );
        expect(strictRes.diagnostics, hasLength(1));
        expect(strictRes.diagnostics.single.code, 'unused_local_variable');
      },
    );

    test(
      'preserves @Tags library annotation before injected imports',
      () async {
        final mdFile = File(p.join(tempDir.path, 'SKILL.md'))
          ..writeAsStringSync('''
```dart
@Tags(['integration'])
import 'package:test/test.dart';
```
''');

        final analyzer = MarkdownDartAnalyzer(
          config: MarkdownAnalyzeConfig(
            fallbackPackageConfigPath: fallbackConfigPath,
          ),
        );
        final res = await analyzer.analyzeFiles(
          contextRoot: tempDir.path,
          markdownRoot: tempDir.path,
          markdownFiles: [mdFile],
        );
        expect(res.diagnostics, isEmpty);
      },
    );

    test(
      'runs consumer-configured SDK lints and skips **Avoid:** anti-pattern blocks',
      () async {
        final mdFile = File(p.join(tempDir.path, 'SKILL.md'))
          ..writeAsStringSync('''
**Avoid:**
```dart
final bad = 'hello ' + 'world';
```

**Good:**
```dart
@Tags(['integration'])
import 'package:test/test.dart';
```
''');

        final analyzer = MarkdownDartAnalyzer(
          config: MarkdownAnalyzeConfig(
            fallbackPackageConfigPath: fallbackConfigPath,
            enabledLints: const {
              'prefer_adjacent_string_concatenation',
              'library_annotations',
            },
          ),
        );
        final res = await analyzer.analyzeFiles(
          contextRoot: tempDir.path,
          markdownRoot: tempDir.path,
          markdownFiles: [mdFile],
        );
        expect(res.diagnostics, hasLength(1));
        expect(res.diagnostics.single.code, 'library_annotations');
      },
    );
  });

  group('Real Repository Integration Verification', () {
    test(
      'google/skills_lint.dart matches exact shrink-only allowlist of 4 real bugs',
      () async {
        const skillsLintRoot =
            '/usr/local/google/home/reidbaker/agent/mark/repos/skills_lint.dart';
        if (!Directory(skillsLintRoot).existsSync()) {
          return;
        }

        final analyzer = MarkdownDartAnalyzer(
          config: MarkdownAnalyzeConfig(
            fallbackPackageConfigPath: fallbackConfigPath,
            ambientImports: const [
              "import 'dart:async';",
              "import 'dart:io';",
              "import 'dart:math' as math;",
              "import 'package:path/path.dart' as p;",
              "import 'package:path/path.dart' as path;",
              "import 'package:skills_lint/skills_lint.dart';",
              "import 'package:test/test.dart';",
            ],
          ),
        );

        final result = await analyzer.analyzeDirectory(
          contextRoot: '$skillsLintRoot/packages/skills_lint',
          markdownRoot: skillsLintRoot,
        );

        expect(result.totalBlocks, 105);
        final failingLocations = {
          for (final d in result.diagnostics) d.block.location,
        };
        expect(
          failingLocations,
          equals({
            '.agents/skills/add-dart-lint-validation-rule/SKILL.md:26-42',
            '.agents/skills/add-dart-lint-validation-rule/SKILL.md:68-74',
            '.agents/skills/add-dart-lint-validation-rule/SKILL.md:80-90',
            '.agents/skills/dart-migrate-to-checks-package/SKILL.md:169-174',
          }),
        );
      },
    );

    test(
      'dart-lang/skills standalone repo catches exact 4 issues + 2 expected errors',
      () async {
        const dartSkillsRoot =
            '/usr/local/google/home/reidbaker/agent/mark/repos/dart_skills';
        if (!Directory(dartSkillsRoot).existsSync()) {
          return;
        }

        final analyzer = MarkdownDartAnalyzer(
          config: MarkdownAnalyzeConfig(
            fallbackPackageConfigPath: fallbackConfigPath,
          ),
        );

        final result = await analyzer.analyzeDirectory(
          contextRoot: dartSkillsRoot,
          markdownRoot: dartSkillsRoot,
        );

        expect(result.totalBlocks, 111);
        expect(result.verifiedExpectedErrorBlocks, 2);
        final failingLocations = {
          for (final d in result.diagnostics) d.block.location,
        };
        expect(
          failingLocations,
          equals({
            'skills/dart-migrate-to-checks-package/SKILL.md:169-174',
            'skills/dart-use-doc-examples/SKILL.md:49-56',
            'skills/dart-use-ffigen/SKILL.md:42-55',
            'skills/dart-use-primary-constructors/SKILL.md:97-100',
          }),
        );
      },
    );

    test(
      'flutter/skills standalone repo suppresses unresolved StatelessWidget superclass cascades',
      () async {
        const flutterSkillsRoot =
            '/usr/local/google/home/reidbaker/agent/mark/repos/flutter_skills';
        if (!Directory(flutterSkillsRoot).existsSync()) {
          return;
        }

        final analyzer = MarkdownDartAnalyzer(
          config: MarkdownAnalyzeConfig(
            fallbackPackageConfigPath: fallbackConfigPath,
          ),
        );

        final result = await analyzer.analyzeDirectory(
          contextRoot: flutterSkillsRoot,
          markdownRoot: flutterSkillsRoot,
        );

        expect(result.totalBlocks, 145);
        expect(result.verifiedExpectedErrorBlocks, 2);
        final failingLocations = {
          for (final d in result.diagnostics) d.block.location,
        };
        expect(
          failingLocations,
          equals({
            '.agents/agents/reidbaker-agent/skills/code-documentation/references/dart.md:15-20',
            '.agents/agents/reidbaker-agent/skills/code-documentation/references/dart.md:66-74',
            'skills/dart-migrate-to-checks-package/SKILL.md:169-174',
            'skills/dart-use-doc-examples/SKILL.md:49-56',
            'skills/dart-use-ffigen/SKILL.md:42-55',
            'skills/dart-use-primary-constructors/SKILL.md:97-100',
          }),
        );
      },
    );
  });
}
