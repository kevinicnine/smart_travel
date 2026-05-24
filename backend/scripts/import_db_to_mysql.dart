import 'dart:convert';
import 'dart:io';

import '../lib/src/data_store.dart';
import '../lib/src/models.dart';

void main() async {
  final mysql = MySqlConfig.fromEnv();
  if (mysql == null) {
    stderr.writeln('請先設定 MYSQL_HOST/MYSQL_PORT/MYSQL_USER/MYSQL_PASSWORD/MYSQL_DATABASE');
    exit(1);
  }
  final dbPath = File('data/db.json');
  if (!dbPath.existsSync()) {
    stderr.writeln('找不到 data/db.json');
    exit(1);
  }
  final raw = jsonDecode(await dbPath.readAsString()) as Map<String, dynamic>;
  final data = BackendData.fromJson(raw);
  final store = DataStore.create(dataDirectory: 'data', mysql: mysql);
  await store.saveWithProgress(data, onProgress: (message) {
    stdout.writeln(message);
  });
  stdout.writeln('已將 db.json 匯入 MySQL');
}
