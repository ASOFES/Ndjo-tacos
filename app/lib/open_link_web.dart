import 'dart:html' as html;

Future<void> openExternal(String url) async {
  html.window.open(url, '_blank');
}

Future<void> printHtml(String htmlDoc, {String? pdfUrl}) async {
  final blob = html.Blob([htmlDoc], 'text/html;charset=utf-8');
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.window.open(url, '_blank');
}
