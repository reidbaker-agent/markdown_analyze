# `package:markdown_analyze` — Architecture & Maintainer Guide

## 1. Purpose & Problem Statement
Dart and Flutter repositories contain hundreds of fenced ```` ```dart ```` blocks in `SKILL.md` files, `README.md`s, architecture docs, and issue templates. Existing tools either only check syntax without type/API resolution (`parseString`), only check `///` doc comments inside `.dart` files (`dartdoc_test`), or require external `.dart` excerpt files and synchronization scripts (`update_excerpts_command.dart`, `excerpter`).

`package:markdown_analyze` (`https://github.com/reidbaker-agent/markdown_analyze`) deterministically extracts, wraps, resolves, and lints fenced Dart code blocks directly in Markdown files—both inside Dart packages and in standalone Markdown-only repositories (`dart-lang/skills`, `flutter/skills`)—with consumer-configurable diagnostic severities and zero false positives.

---

## 2. End-to-End Architecture

```
Markdown Files (.md)
  │
  ├─► 1. Extractor (`lib/src/extractor.dart`)
  │     Tracks outer fences (````markdown) so nested example fences aren't misparsed.
  │     Detects opt-out info strings (`dart no-analyze`, `ignore`) and context markers:
  │       • `isExpectedErrorExample` (`// Error:`, `// ERROR`, or preceding error heading)
  │       • `isAntiPatternExample` (`// Bad`, `// Avoid`, `**Avoid:**`)
  │
  ├─► 2. Progressive Wrapper & Contrast Splitter (`lib/src/wrapper.dart`)
  │     • Tries 7 candidate templates (`unit`, `main-body`, `expression`,
  │       `collection-element`, `class-member`, `imports+main-body`, `named-ctor-class`)
  │       using `parseString` with Dart 3.12+ experiments (`primary-constructors`,
  │       `dot-shorthands`, `enhanced-parts`).
  │     • Strict pass runs first; if syntax fails and `allowEllipsis: true`, retries
  │       after replacing documentation ellipsis idioms (`class Foo { ... }` -> `{}`,
  │       `=> ...;`, `{ ... }`, `(...)`, and closing truncated class bodies).
  │     • Splits single blocks containing both `// Bad` and `// Good` (or `// Before`
  │       and `// After`) into independent sub-snippets (`splitContrastSubSnippets`)
  │       so redefined classes/functions do not self-shadow.
  │
  ├─► 3. In-Memory Semantic Analysis (`lib/src/analyzer.dart`)
  │     • Wraps `PhysicalResourceProvider.INSTANCE` in an `OverlayResourceProvider`
  │       (zero disk mutation in the target repo).
  │     • Synthesizes an in-memory `pubspec.yaml`, `analysis_options.yaml`, and merged
  │       `.dart_tool/package_config.json` (`buildMergedPackageConfigJson`) with all
  │       relative `rootUri`s normalized to absolute `file://` URIs.
  │     • Accumulates top-level imports and declarations across blocks in the same
  │       `.md` file, and overlays snippets at their repo path when a `// lib/...`
  │       path hint comment is present so relative imports resolve.
  │     • Evaluates `context.currentSession.getErrors(overlayPath)`, filtering to the
  │       snippet's `[bodyStartOffset, bodyEndOffset]` byte range.
  │
  └─► 4. Optional Batch Linter Pass (`_runBatchSdkLinter` in `lib/src/analyzer.dart`)
        • Triggered when `includeRecommendedLints: true` or `enabledLints` is non-empty.
        • Stages non-anti-pattern snippets into a temp directory and runs a single
          `dart analyze --format=json` subprocess (~1.5s for 100+ blocks), mapping
          `LINT` diagnostics within `[bodyStartOffset, bodyEndOffset]` back to the
          originating `MarkdownCodeBlock`.
```

---

## 3. What a Maintainer Needs to Know

### A. Why Semantic Analysis and Linting Use Two Separate Passes
`package:analyzer` on `pub.dev` does **not** bundle `pkg/linter` (`pkg/linter` is an internal Dart SDK package marked `publish_to: none`). Calling `AnalysisContextCollection` in-process produces all syntax, compile-time, type-checking, strict-mode, and analyzer warning/hint codes, but ignores `linter: rules:` unless `registerLintRules()` from `pkg/linter` has been called. To support arbitrary lint rules without depending on unpublished SDK internals, `MarkdownDartAnalyzer` runs semantic analysis in-process and runs `dart analyze --format=json` once in batch only when the consumer enables lints.

### B. Minimum `package:analyzer` Version (`^14.4.0` on Dart 3.12+)
Dart 3.12 added `@Deprecated.implement()` to core types like `RegExp` in `dart:core`. Older `analyzer` versions (e.g. `11.0.0`) do not understand the `.implement` target restriction and treat every `RegExp(...)` constructor call as `deprecated_member_use`. Maintain `analyzer: ^14.4.0` so `dart:core` annotations match the Dart 3.12+ SDK.

### C. Standalone Repos & `fallbackPackageConfigPath`
Repositories like `dart-lang/skills` and `flutter/skills` contain `.md` files with no `pubspec.yaml`. `buildMergedPackageConfigJson` merges packages from the target repo (if any) with an optional `fallbackPackageConfigPath`, rewriting every relative `rootUri` (`../../...`) against the source `package_config.json`'s directory before overlaying it into `contextRoot/.dart_tool/package_config.json`. It also injects a synthetic `_standalone_markdown_target` package entry (`languageVersion: 3.12`) so package-relative URIs work cleanly.

### D. Sample-Code Defaults vs. Real Bug Detection
Documentation snippets differ from production files in three predictable ways, each handled explicitly in `analyzer.dart`:
1. **Unused & boilerplate diagnostics (`defaultSampleIgnoredCodes`)**: Ignores `unused_import`, `unused_local_variable`, `unused_element`, `unused_field`, `avoid_print`, `prefer_const_constructors`, `unreachable_from_main`, `dangling_library_doc_comments`, `depend_on_referenced_packages`, and `no_leading_underscores_for_local_identifiers` by default. Any consumer can re-enable any of these via `severityOverrides: {'unused_local_variable': MarkdownDiagnosticSeverity.warning}`.
2. **Illustrative placeholder symbols (`ignoreUnboundPlaceholders: true`)**: Snippets often call `fetchData()` or reference `MyWidget` without defining them. When an unbound identifier (`undefined_identifier`, `undefined_function`, `undefined_class`, `extends_non_class`, etc.) occurs in a snippet, it evaluates to `InvalidType`. `analyzer.dart` suppresses the unbound symbol code plus two specific cascade sets:
   - `cascadingUnboundDiagnosticCodes`: Diagnostics triggered by `InvalidType` (`argument_type_not_assignable`, `unchecked_use_of_nullable_value`, etc.) **only when** an unbound placeholder exists in the same snippet.
   - `cascadingUnresolvedSuperclassCodes`: Suppresses `super_formal_parameter_without_associated_named`, `override_on_non_overriding_member`, and `undefined_super_member_read` **only when `extends_non_class` is also present** in the snippet. This silences `StatelessWidget`/`State` cascades when `package:flutter` isn't in `package_config.json`, while still catching broken `super.` parameters or bad `@override`s when the superclass *does* resolve (such as `class MyNewRule extends SkillRule`).
3. **Intentional compile-error examples (`isExpectedErrorExample`)**: Snippets containing `// Error:` / `// ERROR` or preceded by headings like `Fails Static Analysis` are expected to produce diagnostics and increment `verifiedExpectedErrorBlocks` rather than failing the run.

### E. Byte-Offset Filtering (`[bodyStartOffset, bodyEndOffset]`)
Because `analyzer.dart` prepends accumulated `fileImports` and `priorDecls` from earlier blocks in the same `.md` file (or appends them when the snippet starts with `library;` or `@TestOn(...)`), every wrapped snippet tracks `[bodyStartOffset, bodyEndOffset]`. Only diagnostics whose offset falls inside the current snippet's own body range are reported.
