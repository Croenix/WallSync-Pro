enum ProcessMode {
  main,
  classic,
  wallpaper;

  String get value => switch (this) {
    ProcessMode.main => 'main',
    ProcessMode.classic => 'classic',
    ProcessMode.wallpaper => 'wallpaper',
  };

  bool get isOverlay => this == ProcessMode.classic;
}

class ParsedProcessArguments {
  const ParsedProcessArguments({
    required this.mode,
    required this.startupTrigger,
    required this.startupRegistration,
    required this.silent,
    this.instanceId,
    this.templateId,
    this.operationId,
    this.configurationRevision = 1,
    this.videoPath,
    this.initialTab,
  });

  final ProcessMode mode;
  final String startupTrigger;
  final bool startupRegistration;
  final bool silent;
  final String? instanceId;
  final String? templateId;
  final int? operationId;
  final int configurationRevision;
  final String? videoPath;
  final String? initialTab;
}

ParsedProcessArguments parseProcessArguments(List<String> arguments) {
  var overlay = false;
  var wallpaper = false;
  var startupRegistration = false;
  var silent = false;
  var mainWindowFlag = false;
  String? overlayType;
  String? startupTrigger;
  String? instanceId;
  String? templateId;
  int? operationId;
  int? configurationRevision;
  String? videoPath;
  String? initialTab;
  final seen = <String>{};

  void markSeen(String name) {
    if (!seen.add(name)) {
      throw FormatException('Duplicate process argument: $name');
    }
  }

  String readValue(String argument, String name) {
    final value = argument.substring(name.length + 1).trim();
    if (value.isEmpty) throw FormatException('Missing value for $name');
    return value;
  }

  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--overlay') {
      markSeen(argument);
      overlay = true;
    } else if (argument == '--wallpaper') {
      markSeen(argument);
      wallpaper = true;
    } else if (argument == '--sync-startup-registration') {
      markSeen(argument);
      startupRegistration = true;
    } else if (argument == '--silent') {
      markSeen(argument);
      silent = true;
    } else if (argument == '--minimized' || argument == '--tray') {
      markSeen(argument);
      mainWindowFlag = true;
    } else if (argument == '--video-path') {
      markSeen(argument);
      if (index + 1 >= arguments.length ||
          arguments[index + 1].startsWith('--')) {
        throw const FormatException('Missing value for --video-path');
      }
      videoPath = arguments[++index];
    } else if (argument.startsWith('--video-path=')) {
      markSeen('--video-path');
      videoPath = readValue(argument, '--video-path');
    } else if (argument.startsWith('--overlay-type=')) {
      markSeen('--overlay-type');
      overlayType = readValue(argument, '--overlay-type').toLowerCase();
    } else if (argument.startsWith('--startup-trigger=')) {
      markSeen('--startup-trigger');
      startupTrigger = readValue(argument, '--startup-trigger');
    } else if (argument.startsWith('--instance-id=')) {
      markSeen('--instance-id');
      instanceId = readValue(argument, '--instance-id');
      if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(instanceId)) {
        throw const FormatException(
          '--instance-id may contain only letters, numbers, "_" and "-"',
        );
      }
    } else if (argument.startsWith('--template-id=')) {
      markSeen('--template-id');
      templateId = readValue(argument, '--template-id');
      if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(templateId)) {
        throw const FormatException(
          '--template-id may contain only letters, numbers, "_" and "-"',
        );
      }
    } else if (argument.startsWith('--operation-id=')) {
      markSeen('--operation-id');
      operationId = int.tryParse(readValue(argument, '--operation-id'));
      if (operationId == null || operationId < 0) {
        throw const FormatException(
          '--operation-id must be a non-negative integer',
        );
      }
    } else if (argument.startsWith('--config-revision=')) {
      markSeen('--config-revision');
      configurationRevision = int.tryParse(
        readValue(argument, '--config-revision'),
      );
      if (configurationRevision == null || configurationRevision < 1) {
        throw const FormatException(
          '--config-revision must be a positive integer',
        );
      }
    } else if (argument.startsWith('--open-tab=')) {
      markSeen('--open-tab');
      initialTab = readValue(argument, '--open-tab');
    } else if (argument.startsWith('--vm-service-port=') ||
        argument.startsWith('--observatory-port=') ||
        argument.startsWith('--flutter-assets-dir=')) {
      continue;
    } else {
      throw FormatException('Unknown process argument: $argument');
    }
  }

  if (overlay && wallpaper) {
    throw const FormatException(
      '--overlay and --wallpaper cannot be used together',
    );
  }
  if (overlayType != null && !overlay) {
    throw const FormatException('--overlay-type requires --overlay');
  }
  if (startupRegistration && (overlay || wallpaper)) {
    throw const FormatException(
      '--sync-startup-registration is only valid in main mode',
    );
  }
  if (!overlay &&
      (instanceId != null || templateId != null || operationId != null)) {
    throw const FormatException(
      '--instance-id, --template-id and --operation-id require --overlay',
    );
  }
  if (configurationRevision != null && !overlay) {
    throw const FormatException('--config-revision requires --overlay');
  }
  if ((silent || mainWindowFlag) && (overlay || wallpaper)) {
    throw const FormatException(
      '--silent, --minimized and --tray are only valid in main mode',
    );
  }

  final mode = wallpaper
      ? ProcessMode.wallpaper
      : overlay
      ? switch (overlayType ?? 'classic') {
          'classic' => ProcessMode.classic,
          _ => throw FormatException('Unsupported overlay type: $overlayType'),
        }
      : ProcessMode.main;

  return ParsedProcessArguments(
    mode: mode,
    startupTrigger: startupTrigger ?? 'manual',
    startupRegistration: startupRegistration,
    silent: silent,
    instanceId: instanceId,
    templateId: templateId,
    operationId: operationId,
    configurationRevision: configurationRevision ?? 1,
    videoPath: videoPath,
    initialTab: initialTab,
  );
}
