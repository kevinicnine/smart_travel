import 'dart:io';

import 'package:postgres/postgres.dart';

import '../lib/src/data_store.dart';

String _env(String key, [String fallback = '']) =>
    Platform.environment[key] ?? fallback;

Future<void> _tryConnect({
  required String host,
  required int port,
  required String database,
  required String user,
  required String password,
  required bool useSsl,
  required int timeoutInSeconds,
}) async {
  final conn = PostgreSQLConnection(
    host,
    port,
    database,
    username: user,
    password: password,
    useSSL: useSsl,
    timeoutInSeconds: timeoutInSeconds,
  );
  final label = 'host=$host port=$port ssl=$useSsl timeout=${timeoutInSeconds}s';
  final startedAt = DateTime.now();
  stdout.writeln('TRY  $label');
  try {
    await conn.open();
    final result = await conn.query('select 1 as ok');
    final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
    stdout.writeln('PASS $label (${elapsed}ms) rows=${result.length}');
  } catch (error) {
    final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
    stdout.writeln('FAIL $label (${elapsed}ms) $error');
  } finally {
    if (conn.isClosed == false) {
      await conn.close();
    }
  }
}

Future<void> main() async {
  final host = _env('DB_HOST');
  final database = _env('DB_NAME');
  final user = _env('DB_USER');
  final password = _env('DB_PASSWORD');
  final rawPort = _env('DB_PORT', '5432');
  final port = int.tryParse(rawPort) ?? 5432;

  if (host.isEmpty || database.isEmpty || user.isEmpty) {
    stderr.writeln('Missing DB_HOST/DB_NAME/DB_USER in environment.');
    exitCode = 1;
    return;
  }

  final ports = <int>{port, 5432, 6543}.toList()..sort();
  for (final testPort in ports) {
    await _tryConnect(
      host: host,
      port: testPort,
      database: database,
      user: user,
      password: password,
      useSsl: true,
      timeoutInSeconds: 8,
    );
    await _tryConnect(
      host: host,
      port: testPort,
      database: database,
      user: user,
      password: password,
      useSsl: false,
      timeoutInSeconds: 8,
    );
  }

  stdout.writeln('--- datastore smoke test ---');
  final config = PostgresConfig(
    host: host,
    port: port,
    user: user,
    password: password,
    database: database,
    useSsl: (_env('DB_SSL', 'true').toLowerCase() != 'false'),
  );
  final store = PostgresDataStore(config);
  try {
    final found = await store.findByUsername('testuser');
    stdout.writeln('DATASTORE PASS findByUsername(testuser) => ${found?.id ?? 'null'}');
  } catch (error) {
    stdout.writeln('DATASTORE FAIL $error');
  }
}
