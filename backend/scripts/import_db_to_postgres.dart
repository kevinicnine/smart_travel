import 'dart:convert';
import 'dart:io';

import '../lib/src/data_store.dart';
import '../lib/src/models.dart';

Future<void> main() async {
  final config = PostgresConfig.fromEnv();
  if (config == null) {
    stderr.writeln('請先設定 DB_HOST/DB_PORT/DB_USER/DB_PASSWORD/DB_NAME');
    exit(1);
  }

  final dataFile = File('data/db.json');
  if (!await dataFile.exists()) {
    stderr.writeln('找不到 data/db.json，請確認在 backend 資料夾執行');
    exit(1);
  }

  final raw = await dataFile.readAsString();
  if (raw.trim().isEmpty) {
    stderr.writeln('data/db.json 是空的');
    exit(1);
  }

  final Map<String, dynamic> json = jsonDecode(raw) as Map<String, dynamic>;
  final data = BackendData.fromJson(json);

  final store = PostgresDataStore(config);
  await store.saveWithProgress(
    data,
    onProgress: (msg) => stdout.writeln(msg),
  );
}
