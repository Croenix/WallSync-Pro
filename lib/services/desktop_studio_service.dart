import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/desktop_studio_template.dart';
import 'settings_service.dart';

/// Central service managing WallSync Desktop Studio templates,
/// undo/redo history, user customizations, and live desktop synchronization.
class DesktopStudioService extends ChangeNotifier {
  static final DesktopStudioService _instance = DesktopStudioService._internal();
  factory DesktopStudioService() => _instance;
  DesktopStudioService._internal();

  static const String _userTemplatesPrefsKey = 'wallsync_studio_user_templates_v1';
  static const String _appliedTemplatePrefsKey = 'wallsync_studio_applied_template_id';
  static const int _maxHistoryDepth = 30;

  final List<DesktopStudioTemplate> _userTemplates = [];
  late DesktopStudioTemplate _currentTemplate;
  final List<DesktopStudioTemplate> _undoStack = [];
  final List<DesktopStudioTemplate> _redoStack = [];

  bool _isInitialized = false;
  bool _isDirty = false;
  String _appliedTemplateId = 'wallsync.preset.centered_dock';

  // Getters
  bool get isInitialized => _isInitialized;
  bool get isDirty => _isDirty;
  String get appliedTemplateId => _appliedTemplateId;
  DesktopStudioTemplate get currentTemplate => _currentTemplate;

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  /// Returns all available templates: Built-in WallSync presets + User created templates.
  List<DesktopStudioTemplate> get allTemplates {
    final list = <DesktopStudioTemplate>[];
    list.addAll(DesktopStudioTemplate.builtInPresets);
    list.addAll(_userTemplates);
    return list;
  }

  /// Returns only user-created custom templates.
  List<DesktopStudioTemplate> get userTemplates => List.unmodifiable(_userTemplates);

  /// Initializes the service and loads saved templates from disk.
  Future<void> init() async {
    if (_isInitialized) return;

    // Default template is Centered Dynamic Dock
    _currentTemplate = DesktopStudioTemplate.centeredDock();

    try {
      final prefs = await SharedPreferences.getInstance();
      _appliedTemplateId = prefs.getString(_appliedTemplatePrefsKey) ?? 'wallsync.preset.centered_dock';

      final userTemplatesJson = prefs.getStringList(_userTemplatesPrefsKey);
      if (userTemplatesJson != null) {
        for (final raw in userTemplatesJson) {
          try {
            final map = jsonDecode(raw) as Map<String, dynamic>;
            final errors = DesktopStudioTemplate.validate(map);
            if (errors.isEmpty) {
              _userTemplates.add(DesktopStudioTemplate.fromJson(map));
            } else {
              debugPrint('[DesktopStudioService] Skipped corrupted user template: $errors');
            }
          } catch (e) {
            debugPrint('[DesktopStudioService] Failed to deserialize template: $e');
          }
        }
      }

      // Check if SettingsService already has an active template
      final settings = SettingsService().settings;
      if (settings.activeDockTemplateId.isNotEmpty) {
        _appliedTemplateId = settings.activeDockTemplateId;
      }

      // Set current template to the currently applied one or default
      final match = allTemplates.firstWhere(
        (t) => t.id == _appliedTemplateId,
        orElse: () => DesktopStudioTemplate.centeredDock(),
      );
      _currentTemplate = match;
    } catch (e) {
      debugPrint('[DesktopStudioService] Init error: $e');
    }

    _isInitialized = true;
    _isDirty = false;
    notifyListeners();
  }

  /// Sets the currently active template in Desktop Studio.
  void selectTemplate(DesktopStudioTemplate template) {
    _currentTemplate = template;
    _undoStack.clear();
    _redoStack.clear();
    _isDirty = false;
    notifyListeners();
  }

  /// Selects a template by its unique ID.
  bool selectTemplateById(String id) {
    try {
      final template = allTemplates.firstWhere((t) => t.id == id);
      selectTemplate(template);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Pushes a new state to the undo history stack and updates the current template.
  void updateCurrentTemplate(DesktopStudioTemplate updated, {bool pushUndo = true}) {
    if (pushUndo) {
      _undoStack.add(_currentTemplate);
      if (_undoStack.length > _maxHistoryDepth) {
        _undoStack.removeAt(0);
      }
      _redoStack.clear();
    }
    _currentTemplate = updated.copyWith(
      updatedAt: DateTime.now().toIso8601String(),
    );
    _isDirty = true;
    notifyListeners();
  }

  /// Undoes the last modification.
  bool undo() {
    if (!canUndo) return false;
    _redoStack.add(_currentTemplate);
    _currentTemplate = _undoStack.removeLast();
    _isDirty = true;
    notifyListeners();
    return true;
  }

  /// Redoes the previously undone modification.
  bool redo() {
    if (!canRedo) return false;
    _undoStack.add(_currentTemplate);
    _currentTemplate = _redoStack.removeLast();
    _isDirty = true;
    notifyListeners();
    return true;
  }

  /// Saves changes to the current template.
  /// If it is a built-in preset, it automatically prompts/saves as a user copy.
  Future<DesktopStudioTemplate> saveCurrentTemplate() async {
    if (_currentTemplate.isBuiltIn) {
      // Auto-save as user copy
      return saveAsNewTemplate('${_currentTemplate.name} (Custom)');
    }

    final index = _userTemplates.indexWhere((t) => t.id == _currentTemplate.id);
    final saved = _currentTemplate.copyWith(
      updatedAt: DateTime.now().toIso8601String(),
    );

    if (index >= 0) {
      _userTemplates[index] = saved;
    } else {
      _userTemplates.add(saved);
    }

    _currentTemplate = saved;
    _isDirty = false;
    await _persistUserTemplates();
    notifyListeners();
    return saved;
  }

  /// Saves the current configuration under a new custom template ID and name.
  Future<DesktopStudioTemplate> saveAsNewTemplate(
    String newName, {
    String category = 'Custom',
    String? author,
  }) async {
    final newId = 'wallsync.user.${DateTime.now().millisecondsSinceEpoch}';
    final now = DateTime.now().toIso8601String();
    final newTemplate = _currentTemplate.copyWith(
      id: newId,
      name: newName.trim().isEmpty ? 'My Custom Dock' : newName.trim(),
      author: author ?? 'WallSync User',
      category: category,
      isBuiltIn: false,
      createdAt: now,
      updatedAt: now,
    );

    _userTemplates.add(newTemplate);
    _currentTemplate = newTemplate;
    _undoStack.clear();
    _redoStack.clear();
    _isDirty = false;

    await _persistUserTemplates();
    notifyListeners();
    return newTemplate;
  }

  /// Duplicates an existing template into a new user template.
  Future<DesktopStudioTemplate?> duplicateTemplate(String templateId) async {
    try {
      final original = allTemplates.firstWhere((t) => t.id == templateId);
      final newId = 'wallsync.user.${DateTime.now().millisecondsSinceEpoch}';
      final now = DateTime.now().toIso8601String();
      final copy = original.copyWith(
        id: newId,
        name: '${original.name} Copy',
        isBuiltIn: false,
        createdAt: now,
        updatedAt: now,
      );

      _userTemplates.add(copy);
      await _persistUserTemplates();
      notifyListeners();
      return copy;
    } catch (e) {
      debugPrint('[DesktopStudioService] Duplicate error: $e');
      return null;
    }
  }

  /// Deletes a user template. Built-in templates cannot be deleted.
  Future<bool> deleteTemplate(String templateId) async {
    final index = _userTemplates.indexWhere((t) => t.id == templateId);
    if (index < 0) return false;

    _userTemplates.removeAt(index);
    if (_currentTemplate.id == templateId) {
      _currentTemplate = DesktopStudioTemplate.centeredDock();
      _undoStack.clear();
      _redoStack.clear();
      _isDirty = false;
    }

    if (_appliedTemplateId == templateId) {
      _appliedTemplateId = 'wallsync.preset.centered_dock';
      await applyTemplateById(_appliedTemplateId);
    }

    await _persistUserTemplates();
    notifyListeners();
    return true;
  }

  /// Applies the current template to the live Windows desktop dock and persists settings.
  Future<void> applyCurrentTemplateToDesktop() async {
    // If dirty and not builtIn, save first
    if (_isDirty && !_currentTemplate.isBuiltIn) {
      await saveCurrentTemplate();
    }

    _appliedTemplateId = _currentTemplate.id;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appliedTemplatePrefsKey, _appliedTemplateId);

    // Save to SettingsService
    final settingsService = SettingsService();
    final templateJson = jsonEncode(_currentTemplate.toJson());
    await settingsService.saveSettings(
      settingsService.settings.copyWith(
        activeDockTemplateId: _appliedTemplateId,
        activeDockTemplateJson: templateJson,
      ),
      immediate: true,
    );

    notifyListeners();
  }

  /// Applies a template by ID directly to the desktop dock.
  Future<bool> applyTemplateById(String templateId) async {
    try {
      final match = allTemplates.firstWhere((t) => t.id == templateId);
      _currentTemplate = match;
      await applyCurrentTemplateToDesktop();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Resets the current template to match one of the 8 original presets.
  void resetCurrentToPreset(String presetId) {
    try {
      final preset = DesktopStudioTemplate.builtInPresets.firstWhere((p) => p.id == presetId);
      updateCurrentTemplate(preset.copyWith(
        id: _currentTemplate.id,
        name: _currentTemplate.name,
        isBuiltIn: _currentTemplate.isBuiltIn,
      ));
    } catch (e) {
      debugPrint('[DesktopStudioService] Reset to preset error: $e');
    }
  }

  /// Exports the given template to a `.wstemplate` JSON file.
  /// Returns the absolute path of the exported file.
  Future<String> exportTemplate(
    DesktopStudioTemplate template, {
    String? targetDirectory,
    String? fileName,
  }) async {
    final dir = targetDirectory != null
        ? Directory(targetDirectory)
        : await getApplicationDocumentsDirectory();

    final safeName = (fileName ?? '${template.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '_')}.wstemplate')
        .replaceAll('.wstemplate.wstemplate', '.wstemplate');
    
    final file = File('${dir.path}${Platform.pathSeparator}$safeName');
    await file.writeAsString(template.toFormattedJson());
    return file.path;
  }

  /// Validates and imports a template from JSON text.
  DesktopStudioTemplate importTemplate(String jsonContent) {
    final Map<String, dynamic> map = jsonDecode(jsonContent) as Map<String, dynamic>;
    final validationErrors = DesktopStudioTemplate.validate(map);
    if (validationErrors.isNotEmpty) {
      throw FormatException('Invalid WallSync Template Schema: ${validationErrors.join(', ')}');
    }

    final newId = 'wallsync.imported.${DateTime.now().millisecondsSinceEpoch}';
    final now = DateTime.now().toIso8601String();

    final imported = DesktopStudioTemplate.fromJson(map).copyWith(
      id: newId,
      isBuiltIn: false,
      createdAt: now,
      updatedAt: now,
    );

    _userTemplates.add(imported);
    _persistUserTemplates();
    notifyListeners();
    return imported;
  }

  /// Imports a `.wstemplate` file from the given file path.
  Future<DesktopStudioTemplate> importTemplateFromFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('Template file does not exist', filePath);
    }
    final content = await file.readAsString();
    return importTemplate(content);
  }

  /// Persists user templates to SharedPreferences.
  Future<void> _persistUserTemplates() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stringList = _userTemplates.map((t) => jsonEncode(t.toJson())).toList();
      await prefs.setStringList(_userTemplatesPrefsKey, stringList);
    } catch (e) {
      debugPrint('[DesktopStudioService] Error saving user templates: $e');
    }
  }
}
