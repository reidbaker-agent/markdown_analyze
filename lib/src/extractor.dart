// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import 'models.dart';

/// Extracts fenced `dart` code blocks from Markdown [content] while tracking
/// outer non-Dart fences (such as ````markdown) so nested example fences are
/// not misparsed.
List<MarkdownCodeBlock> extractMarkdownDartBlocks(
  String filePath,
  String content,
) {
  final lines = const LineSplitter().convert(content);
  final blocks = <MarkdownCodeBlock>[];

  String? fenceMarker;
  String? currentInfo;
  int? startLine;
  final buffer = <String>[];

  final openRegex = RegExp(r'^(\s*)(`{3,}|~{3,})(.*)$');

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (fenceMarker == null) {
      final match = openRegex.firstMatch(line);
      if (match != null) {
        final marker = match.group(2)!;
        final info = match.group(3)!.trim();
        if (info == 'dart' ||
            info.startsWith('dart ') ||
            info.startsWith('dart#')) {
          fenceMarker = marker;
          currentInfo = info;
          startLine = i + 2; // 1-based first line of code inside fence
          buffer.clear();
        } else if (info.isEmpty || !info.contains('`')) {
          fenceMarker = 'IGNORE:$marker';
        }
      }
    } else if (fenceMarker.startsWith('IGNORE:')) {
      final actualMarker = fenceMarker.substring('IGNORE:'.length);
      if (RegExp('^\\s*$actualMarker\\s*\$').hasMatch(line)) {
        fenceMarker = null;
      }
    } else {
      if (RegExp('^\\s*$fenceMarker\\s*\$').hasMatch(line)) {
        final code = buffer.join('\n');
        final firstLine = startLine!;
        final endLine = i; // 1-based line before closing fence
        blocks.add(
          MarkdownCodeBlock(
            filePath: filePath,
            startLine: firstLine,
            endLine: endLine < firstLine ? firstLine : endLine,
            infoString: currentInfo!,
            code: code,
            isExpectedErrorExample: _detectExpectedError(
              lines,
              firstLine,
              code,
            ),
            isAntiPatternExample: _detectAntiPattern(lines, firstLine, code),
          ),
        );
        fenceMarker = null;
        currentInfo = null;
        startLine = null;
      } else {
        buffer.add(line);
      }
    }
  }
  return blocks;
}

bool _detectExpectedError(
  List<String> mdLines,
  int blockStartLine,
  String code,
) {
  if (RegExp(
    r'//\s*(Error:|ERROR\b|Compile-time error)',
    caseSensitive: false,
  ).hasMatch(code)) {
    return true;
  }
  final startIdx = (blockStartLine - 5).clamp(0, blockStartLine - 1);
  for (var i = startIdx; i < blockStartLine - 1 && i < mdLines.length; i++) {
    if (RegExp(
      r'(Fails Static Analysis|INCORRECT|Bad Example|Compile-time error|will fail to compile)',
      caseSensitive: false,
    ).hasMatch(mdLines[i])) {
      return true;
    }
  }
  return false;
}

bool _detectAntiPattern(List<String> mdLines, int blockStartLine, String code) {
  if (RegExp(
    r"^\s*//\s*(Bad|Avoid|DON'T)\b",
    caseSensitive: false,
  ).hasMatch(code)) {
    return true;
  }
  final startIdx = (blockStartLine - 4).clamp(0, blockStartLine - 1);
  for (var i = startIdx; i < blockStartLine - 1 && i < mdLines.length; i++) {
    if (RegExp(
      r'(\*\*Avoid:\*\*|\bBad:|\*Bad\b|Hard to follow:)',
      caseSensitive: false,
    ).hasMatch(mdLines[i])) {
      return true;
    }
  }
  return false;
}
