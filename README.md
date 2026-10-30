# `markdown_analyze`

Deterministic static analysis and linting for Dart code blocks in Markdown files (`SKILL.md`, `README.md`, documentation, agent plans, and issues) using `package:analyzer` and an in-memory `OverlayResourceProvider`.

Built for adoption by [`google/skills_lint.dart`](https://github.com/google/skills_lint.dart) and standalone skills/documentation repositories (`dart-lang/skills`, `flutter/skills`) without requiring external `.dart` excerpt files or `<?code-excerpt>` sync pipelines.

---

## Features & Empirical Design

1. **Zero-Disk-Mutation Overlay Analysis (`OverlayResourceProvider`)**:
   - Analyzes Markdown snippets in-memory against a target package's `.dart_tool/package_config.json` or a merged standalone `package_config.json` for repositories without a `pubspec.yaml` (`dart-lang/skills`, `flutter/skills`).
2. **Consumer-Configurable Diagnostics & Sample-Friendly Defaults (`MarkdownAnalyzeConfig`)**:
   - Defaults noisy sample-code diagnostics to `ignore` (`unused_local_variable`, `unused_element`, `unused_import`, `unused_field`, `avoid_print`, `prefer_const_constructors`, `unreachable_from_main`, `dangling_library_doc_comments`, `depend_on_referenced_packages`).
   - Allows consumers to override any diagnostic or lint severity via `severityOverrides` (`ignore`, `info`, `warning`, `error`).
3. **Empirically Hardened Snippet Wrapping & Context Resolution**:
   - **7-Mode Template Wrapping**: Automatically wraps snippets as `unit`, `main-body` (`Future<Object?> _snippetMain() async`), `expression`, `collection-element`, `class-member` (prioritized when top-level `@override` is present), `imports+main-body`, or `named-ctor-class`, with optional `...` ellipsis sanitization.
   - **Contrast Sub-Snippet Splitting**: Splits single code blocks containing side-by-side `// Before` / `// After` or `// Bad` / `// Good` declarations into separate compilation units so redefined classes (`class DatabaseService`) do not shadow themselves.
   - **File-Level Context Accumulation**: Deduplicates top-level declarations by identifier name (`Map<String, String>`) across sequential snippets in the same `.md` file so later blocks can use earlier classes/functions without `duplicate_definition` collisions.
   - **Path-Hinted Overlay Persistence**: Keeps blocks with leading path comments (`// lib/src/rules/my_new_rule.dart`) in the `OverlayResourceProvider` across the Markdown file so later blocks (`// test/my_new_rule_test.dart`) resolve imports of earlier blocks.
   - **Library Annotation Preservation**: Keeps first-directive annotations (`@Tags`, `@TestOn`, `@Timeout`, `library`) before injected ambient imports.
   - **Cascading Placeholder Filtering**: Distinguishes unresolved placeholder symbols (`InvalidType`, `Subject<InvalidType>`, and `extends_non_class` superclass cascades) from real API/type errors on resolved classes.

---

## Real Bugs Caught Across Target Repositories

| Repository | Total Blocks | False Positives | Real Bugs Caught |
| :--- | ---: | ---: | :--- |
| `google/skills_lint.dart` (non-vendored) | 105 | **0** | **4** (`add-dart-lint-validation-rule/SKILL.md:26-42`, `68-74`, `80-90` drifted from `SkillRule` API; `dart-migrate-to-checks-package/SKILL.md:169-174` unterminated string literal `triggerSync"`) |
| `dart-lang/skills` (standalone) | 111 | **0** | **4** (`dart-use-primary-constructors/SKILL.md:97-100` double-initialized declaring parameter `var int y`; `dart-use-doc-examples/SKILL.md:49-56` 0-arg `Client.send()`; `dart-migrate-to-checks-package/SKILL.md:169-174`; `dart-use-ffigen/SKILL.md:42-55`) + **2** verified expected-error examples |
| `flutter/skills` (standalone) | 145 | **0** | **6** (all 4 above + `code-documentation/references/dart.md:15-20` and `66-74` missing closing `}` on `class FlightPath`) + **2** verified expected-error examples |
