import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> openExternal(String url) async {
  final uri = Uri.parse(url);
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

Future<void> printHtml(String html, {String? pdfUrl}) async {
  if (pdfUrl != null && pdfUrl.isNotEmpty) {
    try {
      await openExternal(pdfUrl);
      return;
    } catch (_) {}
  }
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}ndjo-ticket.html');
    await file.writeAsString(html, flush: true);
    if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', file.path], runInShell: true);
      return;
    }
    await Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [file.path]);
    return;
  }
  final uri = Uri.dataFromString(html, mimeType: 'text/html', encoding: utf8);
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
