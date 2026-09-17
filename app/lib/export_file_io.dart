import 'dart:io';

Future<String> saveNdjoFile(String filename, List<int> bytes, String mime) async {
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? Directory.systemTemp.path;
  final downloads = Directory('$home${Platform.pathSeparator}Downloads');
  final dir = await downloads.exists() ? downloads : Directory.systemTemp;
  final file = File('${dir.path}${Platform.pathSeparator}$filename');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
