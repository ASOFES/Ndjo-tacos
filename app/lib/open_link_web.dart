import 'dart:html' as html;

void openExternal(String url) {
  html.window.open(url, '_blank');
}

void printHtml(String htmlDoc) {
  final blob = html.Blob([htmlDoc], 'text/html');
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.window.open(url, '_blank');
}
