import 'dart:html' as html;

Future<String> saveNdjoFile(String filename, List<int> bytes, String mime) async {
  final blob = html.Blob([bytes], mime);
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..download = filename
    ..click();
  html.Url.revokeObjectUrl(url);
  return filename;
}
