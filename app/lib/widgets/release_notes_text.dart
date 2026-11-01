import 'package:flutter/material.dart';

import '../theme.dart';

/// Shows release notes written in simple Markdown (headings, bullets, **bold**).
class ReleaseNotesText extends StatelessWidget {
  final String markdown;
  const ReleaseNotesText(this.markdown, {super.key});

  List<InlineSpan> _inline(String text, TextStyle base) {
    final spans = <InlineSpan>[];
    final parts = text.split('**');
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isEmpty) continue;
      spans.add(TextSpan(
        text: parts[i].replaceAll('`', '').replaceAll(RegExp(r'(?<!\w)\*(?!\s)|(?<!\s)\*(?!\w)'), ''),
        style: i.isOdd ? base.copyWith(fontWeight: FontWeight.w700, color: SfColors.text) : base,
      ));
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    const body = TextStyle(color: SfColors.textDim, fontSize: 13, height: 1.4);
    final lines = markdown.replaceAll('\r', '').split('\n');
    final children = <Widget>[];
    var firstHeading = true;
    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        children.add(const SizedBox(height: 6));
        continue;
      }
      final h = RegExp(r'^(#+)\s*(.*)$').firstMatch(line);
      if (h != null) {
        // the first "# ScanForge Pro x.y.z" title repeats the version: skip it
        if (firstHeading && h.group(1)!.length == 1) {
          firstHeading = false;
          continue;
        }
        firstHeading = false;
        children.add(Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Text(h.group(2)!.replaceAll('**', ''),
              style: const TextStyle(color: SfColors.accent, fontWeight: FontWeight.w700, fontSize: 13)),
        ));
        continue;
      }
      final b = RegExp(r'^(\s*)[-*]\s+(.*)$').firstMatch(line);
      if (b != null) {
        final indent = (b.group(1)!.length ~/ 2) * 14.0;
        children.add(Padding(
          padding: EdgeInsets.only(left: indent, bottom: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('•  ', style: TextStyle(color: SfColors.accent, fontSize: 13, height: 1.4)),
            Expanded(child: Text.rich(TextSpan(children: _inline(b.group(2)!, body)))),
          ]),
        ));
        continue;
      }
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Text.rich(TextSpan(children: _inline(line.trim(), body))),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}
