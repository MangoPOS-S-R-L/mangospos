import 'dart:io';

const _serviceName = 'MangoPOSAgent';
const _serviceWrapper = 'mangopos-agent-service.exe';
const _agentProcess = 'mangopos-agent.exe';
const _wrapperProcess = 'mangopos-agent-service.exe';
const _firewallRule = 'MangoPOS Agent (9100)';

Future<int> main(List<String> args) async {
  if (!Platform.isWindows) {
    stderr.writeln('Este desinstalador solo funciona en Windows.');
    return 1;
  }

  stdout.writeln('MangoPOS Agent Uninstaller');
  stdout.writeln('==========================');

  if (!await _isAdministrator()) {
    stdout.writeln('Solicitando permisos de administrador...');
    final relaunched = await _relaunchElevated(args);
    return relaunched ? 0 : 1;
  }

  final serviceDir = await _queryInstalledServiceDir();
  final candidateDirs = _buildCandidateDirs(serviceDir);

  await _stopAndUninstallService(candidateDirs);
  await _killProcesses();
  await _removeServiceRegistration();
  await _removeFirewallRule();
  await _removeAgentFiles(candidateDirs);

  stdout.writeln('');
  stdout.writeln('Agente LAN desinstalado.');
  return 0;
}

Future<bool> _isAdministrator() async {
  final result = await Process.run(
    'powershell',
    [
      '-NoProfile',
      '-Command',
      '(New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)',
    ],
    runInShell: true,
  );

  return result.exitCode == 0 &&
      result.stdout.toString().trim().toLowerCase() == 'true';
}

Future<bool> _relaunchElevated(List<String> args) async {
  final exePath = Platform.resolvedExecutable.replaceAll("'", "''");
  final joinedArgs = args
      .map((arg) => "'${arg.replaceAll("'", "''")}'")
      .join(', ');
  final argumentList = args.isEmpty
      ? '@()'
      : '@($joinedArgs)';

  final result = await Process.run(
    'powershell',
    [
      '-NoProfile',
      '-Command',
      "Start-Process -FilePath '$exePath' -ArgumentList $argumentList -Verb RunAs",
    ],
    runInShell: true,
  );

  if (result.exitCode != 0) {
    stderr.writeln('No se pudo relanzar como administrador.');
    stderr.writeln(result.stderr);
    return false;
  }

  return true;
}

Future<String?> _queryInstalledServiceDir() async {
  final result = await Process.run(
    'sc',
    ['qc', _serviceName],
    runInShell: true,
  );
  if (result.exitCode != 0) {
    return null;
  }

  for (final rawLine in result.stdout.toString().split(RegExp(r'[\r\n]+'))) {
    if (!rawLine.contains('BINARY_PATH_NAME')) {
      continue;
    }

    final line = rawLine.split(':').skip(1).join(':').trim();
    if (line.isEmpty) {
      continue;
    }

    final quoted = RegExp(r'"([^"]+\.exe)"', caseSensitive: false).firstMatch(line);
    final extracted = quoted?.group(1) ??
        RegExp(r'([A-Za-z]:\\.*?\.exe)', caseSensitive: false)
            .firstMatch(line)
            ?.group(1);
    if (extracted == null || extracted.isEmpty) {
      continue;
    }

    return File(extracted).parent.path;
  }

  return null;
}

List<Directory> _buildCandidateDirs(String? serviceDir) {
  final dirs = <String>{
    if (serviceDir != null && serviceDir.isNotEmpty) serviceDir,
    if (Platform.environment['ProgramFiles'] != null)
      '${Platform.environment['ProgramFiles']}\\MangoPOS\\Agent',
    if (Platform.environment['ProgramFiles(x86)'] != null)
      '${Platform.environment['ProgramFiles(x86)']}\\MangoPOS\\Agent',
    r'C:\MangoPOS\Agent',
  };

  return dirs
      .map(Directory.new)
      .where((dir) => dir.path.trim().isNotEmpty)
      .toList(growable: false);
}

Future<void> _stopAndUninstallService(List<Directory> candidateDirs) async {
  stdout.writeln('Deteniendo servicio...');

  for (final dir in candidateDirs) {
    final wrapper = File('${dir.path}\\$_serviceWrapper');
    if (!wrapper.existsSync()) {
      continue;
    }

    await _runQuiet(wrapper.path, ['stop']);
    await _runQuiet(wrapper.path, ['uninstall']);
  }
}

Future<void> _killProcesses() async {
  stdout.writeln('Cerrando procesos del agente...');
  await _runQuiet('taskkill', ['/F', '/IM', _agentProcess, '/T']);
  await _runQuiet('taskkill', ['/F', '/IM', _wrapperProcess, '/T']);
}

Future<void> _removeServiceRegistration() async {
  stdout.writeln('Eliminando registro del servicio...');
  await _runQuiet('sc', ['delete', _serviceName]);
}

Future<void> _removeFirewallRule() async {
  stdout.writeln('Eliminando regla de firewall...');
  await _runQuiet('netsh', [
    'advfirewall',
    'firewall',
    'delete',
    'rule',
    'name=$_firewallRule',
  ]);
}

Future<void> _removeAgentFiles(List<Directory> candidateDirs) async {
  stdout.writeln('Eliminando archivos del agente...');
  for (final dir in candidateDirs) {
    if (!dir.existsSync()) {
      continue;
    }
    if (!_looksLikeAgentInstallDir(dir.path)) {
      stdout.writeln('Saltando carpeta no segura: ${dir.path}');
      continue;
    }

    try {
      await dir.delete(recursive: true);
      stdout.writeln('Eliminado: ${dir.path}');
    } catch (e) {
      stderr.writeln('No se pudo eliminar ${dir.path}: $e');
    }
  }
}

bool _looksLikeAgentInstallDir(String path) {
  final normalized = path.toLowerCase().replaceAll('/', r'\');
  return normalized.endsWith(r'\mangopos\agent') ||
      normalized == r'c:\mangopos\agent';
}

Future<void> _runQuiet(String executable, List<String> arguments) async {
  try {
    await Process.run(executable, arguments, runInShell: true);
  } catch (_) {
    // Best-effort cleanup. Missing process/service is acceptable.
  }
}
