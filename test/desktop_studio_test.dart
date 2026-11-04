import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wall_sync/models/desktop_studio_template.dart';
import 'package:wall_sync/services/desktop_studio_service.dart';
import 'package:wall_sync/services/settings_service.dart';
import 'package:wall_sync/widgets/template_gallery_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DesktopStudioTemplate Model & Presets', () {
    test('9 Original WallSync Built-In Presets exist and are valid', () {
      final presets = DesktopStudioTemplate.builtInPresets;
      expect(presets.length, equals(9));

      final presetIds = presets.map((p) => p.id).toSet();
      expect(presetIds.length, equals(9)); // All IDs unique

      expect(presetIds, contains('wallsync.preset.centered_dock'));
      expect(presetIds, contains('wallsync.preset.minimal_floating'));
      expect(presetIds, contains('wallsync.preset.floating_shelf'));
      expect(presetIds, contains('wallsync.preset.classic_taskbar'));
      expect(presetIds, contains('wallsync.preset.top_desktop_bar'));
      expect(presetIds, contains('wallsync.preset.animated_windows_taskbar_widget'));
      expect(presetIds, contains('wallsync.preset.widget_focused_bar'));
      expect(presetIds, contains('wallsync.preset.compact_launcher'));
      expect(presetIds, contains('wallsync.preset.custom_layout'));

      for (final preset in presets) {
        expect(preset.isBuiltIn, isTrue);
        expect(
          preset.schemaVersion,
          equals(DesktopStudioTemplate.currentSchemaVersion),
        );
        expect(preset.name, isNotEmpty);
        expect(preset.elements, isNotEmpty);
        expect(preset.layout.thickness, greaterThan(0));
        expect(preset.appearance.borderRadius, greaterThanOrEqualTo(0));

        // Schema validation must report 0 errors for all built-ins
        final errors = DesktopStudioTemplate.validate(preset.toJson());
        expect(
          errors,
          isEmpty,
          reason: 'Preset ${preset.id} failed schema validation: $errors',
        );
      }
    });

    test('Template JSON serialization roundtrip preserves all properties', () {
      final original = DesktopStudioTemplate.centeredDock();
      final jsonMap = original.toJson();
      final restored = DesktopStudioTemplate.fromJson(jsonMap);

      expect(restored.id, equals(original.id));
      expect(restored.name, equals(original.name));
      expect(restored.author, equals(original.author));
      expect(restored.version, equals(original.version));
      expect(restored.category, equals(original.category));
      expect(restored.layout.position, equals(original.layout.position));
      expect(restored.layout.alignment, equals(original.layout.alignment));
      expect(restored.layout.thickness, equals(original.layout.thickness));
      expect(restored.appearance.style, equals(original.appearance.style));
      expect(
        restored.appearance.backgroundColor,
        equals(original.appearance.backgroundColor),
      );
      expect(
        restored.appearance.borderRadius,
        equals(original.appearance.borderRadius),
      );
      expect(
        restored.animation.enableHoverScale,
        equals(original.animation.enableHoverScale),
      );
      expect(
        restored.animation.hoverScaleFactor,
        equals(original.animation.hoverScaleFactor),
      );
      expect(
        restored.animation.hoverLift,
        equals(original.animation.hoverLift),
      );
      expect(restored.elements.length, equals(original.elements.length));
      expect(
        restored.elements
            .where((element) => element.type == DockElementType.pinnedApp)
            .every((element) => element.actionPayload.isNotEmpty),
        isTrue,
      );

      // Test toFormattedJson output is valid JSON
      final formatted = original.toFormattedJson();
      final reDecoded = jsonDecode(formatted) as Map<String, dynamic>;
      expect(reDecoded['name'], equals(original.name));
    });

    test(
      'Schema validation flags missing fields and unknown element types',
      () {
        // Missing name
        final missingName = {
          'schemaVersion': DesktopStudioTemplate.currentSchemaVersion,
          'id': 'test.invalid.id',
          'name': '',
        };
        expect(DesktopStudioTemplate.validate(missingName), isNotEmpty);

        // Incompatible schema version
        final wrongSchema = {
          'schemaVersion': 'unknown.schema.v99',
          'id': 'test.id',
          'name': 'Test',
        };
        final schemaErrors = DesktopStudioTemplate.validate(wrongSchema);
        expect(
          schemaErrors.any((e) => e.contains('Incompatible schema version')),
          isTrue,
        );

        // Unknown element type
        final unknownElement = {
          'schemaVersion': DesktopStudioTemplate.currentSchemaVersion,
          'id': 'test.id',
          'name': 'Test',
          'elements': [
            {'type': 'unsupported_alien_component', 'label': 'Bad Item'},
          ],
        };
        final elementErrors = DesktopStudioTemplate.validate(unknownElement);
        expect(
          elementErrors.any((e) => e.contains('unrecognized type')),
          isTrue,
        );
      },
    );

    test('DockAnimationConfig curve resolving works properly', () {
      const cubicConfig = DockAnimationConfig(curveName: 'easeOutCubic');
      expect(cubicConfig.curve, equals(Curves.easeOutCubic));

      const backConfig = DockAnimationConfig(curveName: 'easeOutBack');
      expect(backConfig.curve, equals(Curves.easeOutBack));

      const quadConfig = DockAnimationConfig(curveName: 'easeOutQuad');
      expect(quadConfig.curve, equals(Curves.easeOutQuad));
    });
  });

  group('Template gallery visibility', () {
    testWidgets('taskbar widgets are shown by default in the gallery', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: TemplateGalleryView(),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Animated Windows Taskbar Widget'), findsOneWidget);
    });
  });

  group('DesktopStudioService Operations', () {
    test(
      'Initialization loads built-ins and sets default active template',
      () async {
        final service = DesktopStudioService();
        await service.init();

        expect(service.isInitialized, isTrue);
        expect(service.allTemplates.length, greaterThanOrEqualTo(9));
        expect(
          service.currentTemplate.id,
          equals('wallsync.preset.centered_dock'),
        );
        expect(service.isDirty, isFalse);
      },
    );

    test(
      'Undo and Redo stack management works with pushState and modifications',
      () async {
        final service = DesktopStudioService();
        await service.init();

        final initial = service.currentTemplate;
        expect(service.canUndo, isFalse);
        expect(service.canRedo, isFalse);

        // Modify thickness
        final modified1 = initial.copyWith(
          layout: initial.layout.copyWith(thickness: 72.0),
        );
        service.updateCurrentTemplate(modified1);

        expect(service.currentTemplate.layout.thickness, equals(72.0));
        expect(service.canUndo, isTrue);
        expect(service.isDirty, isTrue);

        // Modify border radius
        final modified2 = service.currentTemplate.copyWith(
          appearance: service.currentTemplate.appearance.copyWith(
            borderRadius: 30.0,
          ),
        );
        service.updateCurrentTemplate(modified2);

        expect(service.currentTemplate.appearance.borderRadius, equals(30.0));
        expect(service.canUndo, isTrue);

        // Undo 1
        final undone1 = service.undo();
        expect(undone1, isTrue);
        expect(
          service.currentTemplate.appearance.borderRadius,
          equals(initial.appearance.borderRadius),
        );
        expect(service.currentTemplate.layout.thickness, equals(72.0));
        expect(service.canRedo, isTrue);

        // Undo 2
        final undone2 = service.undo();
        expect(undone2, isTrue);
        expect(
          service.currentTemplate.layout.thickness,
          equals(initial.layout.thickness),
        );
        expect(service.canUndo, isFalse);

        // Redo 1
        final redone1 = service.redo();
        expect(redone1, isTrue);
        expect(service.currentTemplate.layout.thickness, equals(72.0));
      },
    );

    test(
      'Save As New Template persists custom template and sets active',
      () async {
        final service = DesktopStudioService();
        await service.init();

        final created = await service.saveAsNewTemplate(
          'My Gamer Dock',
          category: 'Gaming',
        );

        expect(created.name, equals('My Gamer Dock'));
        expect(created.category, equals('Gaming'));
        expect(created.isBuiltIn, isFalse);
        expect(service.isDirty, isFalse);
        expect(service.userTemplates.any((t) => t.id == created.id), isTrue);

        // Select another template then re-select custom
        service.selectTemplateById('wallsync.preset.minimal_floating');
        expect(
          service.currentTemplate.name,
          equals('Minimal Floating Taskbar'),
        );

        final selectedBack = service.selectTemplateById(created.id);
        expect(selectedBack, isTrue);
        expect(service.currentTemplate.name, equals('My Gamer Dock'));
      },
    );

    test('Duplicate and Delete template workflows', () async {
      final service = DesktopStudioService();
      await service.init();

      final duplicated = await service.duplicateTemplate(
        'wallsync.preset.top_desktop_bar',
      );
      expect(duplicated, isNotNull);
      expect(duplicated!.name, equals('Top Desktop Bar Copy'));
      expect(duplicated.isBuiltIn, isFalse);
      expect(service.userTemplates.any((t) => t.id == duplicated.id), isTrue);

      final deleted = await service.deleteTemplate(duplicated.id);
      expect(deleted, isTrue);
      expect(service.userTemplates.any((t) => t.id == duplicated.id), isFalse);
    });

    test('Export and Import (.wstemplate) workflow', () async {
      final service = DesktopStudioService();
      await service.init();

      final tempDir = Directory.systemTemp.createTempSync('wstemplate_test');
      try {
        final template = DesktopStudioTemplate.minimalFloating();
        final exportedPath = await service.exportTemplate(
          template,
          targetDirectory: tempDir.path,
          fileName: 'custom_minimal.wstemplate',
        );

        final exportedFile = File(exportedPath);
        expect(exportedFile.existsSync(), isTrue);

        final rawContent = exportedFile.readAsStringSync();
        expect(rawContent, contains('wallsync.dock.template.v1'));

        // Import from string content
        final imported = service.importTemplate(rawContent);
        expect(imported.name, equals(template.name));
        expect(imported.isBuiltIn, isFalse);
        expect(service.userTemplates.any((t) => t.id == imported.id), isTrue);

        // Import from file
        final importedFromFile = await service.importTemplateFromFile(
          exportedPath,
        );
        expect(importedFromFile.name, equals(template.name));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'Apply template persists to SettingsService and SharedPreferences',
      () async {
        final service = DesktopStudioService();
        await service.init();

        service.selectTemplateById('wallsync.preset.widget_focused_bar');
        await service.applyCurrentTemplateToDesktop();

        expect(
          service.appliedTemplateId,
          equals('wallsync.preset.widget_focused_bar'),
        );

        final settings = SettingsService().settings;
        expect(
          settings.activeDockTemplateId,
          equals('wallsync.preset.widget_focused_bar'),
        );
        expect(settings.activeDockTemplateJson, isNotNull);
        expect(
          settings.activeDockTemplateJson,
          contains('Widget-Focused Desktop Bar'),
        );
      },
    );
  });
}
