// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Drop-in `repo_test/markdown_dart_blocks_test.dart` for `google/skills_lint.dart`.
///
/// Scans every non-vendored `.md` file in `google/skills_lint.dart` (`SKILL.md`,
/// `README.md`, `RULES.md`, and `documentation/knowledge/*.md`) using
/// `package:markdown_analyze` and enforces a shrink-only allowlist for the
/// 4 pre-existing broken blocks in `.agents/skills/`.
library;

import 'package:markdown_analyze/markdown_analyze.dart';
import 'package:test/test.dart';

/// Pre-existing broken Markdown Dart code blocks in `google/skills_lint.dart`.
/// Shrink-only: fix new violations rather than adding entries, and remove
/// entries as existing skills are fixed.
const Set<String> _shouldBeFixed = {
  '.agents/skills/add-dart-lint-validation-rule/SKILL.md:26-42',
  '.agents/skills/add-dart-lint-validation-rule/SKILL.md:68-74',
  '.agents/skills/add-dart-lint-validation-rule/SKILL.md:80-90',
  '.agents/skills/dart-migrate-to-checks-package/SKILL.md:169-174',
};

void main() {
  late MarkdownAnalysisResult result;

  setUpAll(() async {
    final analyzer = MarkdownDartAnalyzer(
      config: const MarkdownAnalyzeConfig(
        ambientImports: [
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
    result = await analyzer.analyzeDirectory(
      contextRoot: '.',
      markdownRoot: '../..',
    );
  });

  test('no Markdown Dart block has unexpected syntax, type, or API errors', () {
    final unexpected = [
      for (final d in result.diagnostics)
        if (!_shouldBeFixed.contains(d.block.location)) d.describe(),
    ];
    expect(unexpected, isEmpty, reason: unexpected.join('\n'));
  });

  test('_shouldBeFixed only lists blocks that still have errors', () {
    final activeLocations = {
      for (final d in result.diagnostics) d.block.location,
    };
    final stale = _shouldBeFixed.difference(activeLocations).toList()..sort();
    expect(
      stale,
      isEmpty,
      reason: 'Remove fixed entries from _shouldBeFixed:\n${stale.join('\n')}',
    );
  });
}
