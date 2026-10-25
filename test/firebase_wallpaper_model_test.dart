import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/firebase_service.dart';

void main() {
  test(
    'wallpaper cache names are safe and change when the source URL changes',
    () {
      final original = FirebaseWallpaper(
        id: '../wallpaper',
        name: 'Wall',
        category: 'Test',
        type: 'static',
        url: 'https://cdn.example.com/wallpaper.png?version=1',
      );
      final updated = FirebaseWallpaper(
        id: '../wallpaper',
        name: 'Wall',
        category: 'Test',
        type: 'static',
        url: 'https://cdn.example.com/wallpaper.png?version=2',
      );

      expect(original.filename, isNot(contains('..')));
      expect(original.filename, isNot(contains('/')));
      expect(original.filename, isNot(contains(r'\')));
      expect(original.filename, isNot(updated.filename));
    },
  );

  test(
    'catalog refresh detects metadata and source URL changes for same ID',
    () {
      final current = FirebaseWallpaper(
        id: 'wallpaper-1',
        name: 'Night Sky',
        category: 'Nature',
        type: 'static',
        url: 'https://cdn.example.com/night-sky.png?version=1',
        thumbnailUrl: 'https://cdn.example.com/night-sky-thumb.png',
      );
      final unchanged = FirebaseWallpaper(
        id: 'wallpaper-1',
        name: 'Night Sky',
        category: 'Nature',
        type: 'static',
        url: 'https://cdn.example.com/night-sky.png?version=1',
        thumbnailUrl: 'https://cdn.example.com/night-sky-thumb.png',
      );
      final updated = FirebaseWallpaper(
        id: 'wallpaper-1',
        name: 'Night Sky Remastered',
        category: 'Nature',
        type: 'static',
        url: 'https://cdn.example.com/night-sky.png?version=2',
        thumbnailUrl: 'https://cdn.example.com/night-sky-thumb-v2.png',
      );

      expect(
        FirebaseService.catalogHasChanges([current], [unchanged]),
        isFalse,
      );
      expect(FirebaseService.catalogHasChanges([current], [updated]), isTrue);
    },
  );

  test(
    'malformed optional Firebase fields do not invalidate the catalog item',
    () {
      final wallpaper = FirebaseWallpaper.fromJson('image-1', {
        'name': 42,
        'category': null,
        'type': false,
        'url': 7,
        'description': [],
      });

      expect(wallpaper.name, 'Wallpaper image-1');
      expect(wallpaper.category, 'General');
      expect(wallpaper.type, 'static');
      expect(wallpaper.url, isEmpty);
      expect(wallpaper.description, isNull);
    },
  );

  test('catalog deduplication keeps one item per stable ID', () {
    final first = FirebaseWallpaper(
      id: 'wallpaper-1',
      name: 'Aurora',
      category: 'Nature',
      type: 'static',
      url: 'https://cdn.example.net/aurora-one.png',
    );
    final duplicate = FirebaseWallpaper(
      id: 'wallpaper-1',
      name: 'Aurora',
      category: 'Nature',
      type: 'static',
      url: 'https://cdn.example.net/aurora-two.png',
      thumbnailUrl: 'https://cdn.example.net/aurora-thumb.png',
    );

    final result = FirebaseService.deduplicateWallpapers([first, duplicate]);

    expect(result, hasLength(1));
    expect(result.single.thumbnailUrl, duplicate.thumbnailUrl);
  });

  test(
    'uses the catalog key as the stable wallpaper ID and parses dimensions',
    () {
      final wallpaper = FirebaseWallpaper.fromJson('stable-wallpaper-id', {
        'id': 'legacy-title-based-id',
        'wallpaperId': 'another-stale-id',
        'name': 'Aurora',
        'type': 'static',
        'url': 'https://cdn.example.net/aurora.png',
        'width': 3840,
        'height': 2160,
        'resolutionSource': 'original-image',
        'resolutionVerified': true,
      });

      expect(wallpaper.id, 'stable-wallpaper-id');
      expect(wallpaper.width, 3840);
      expect(wallpaper.height, 2160);
      expect(wallpaper.resolutionLabel, '4K');
      expect(wallpaper.resolutionSource, 'original-image');
      expect(wallpaper.resolutionVerified, isTrue);
      expect(wallpaper.toJson()['wallpaperId'], wallpaper.id);
    },
  );

  test(
    'video wallpapers do not assign external stock photos as default thumbnail',
    () {
      final videoWallpaper = FirebaseWallpaper.fromJson('video-1', {
        'name': 'Dancing in Neon Lights',
        'category': 'Cyberpunk',
        'type': 'video',
        'url': 'https://assets.mixkit.co/videos/1240/1240-720.mp4',
      });

      // Default thumbnail should never be an external Unsplash or stock URL
      expect(videoWallpaper.thumbnailUrl, isNull);
    },
  );

  test('video source URLs are never accepted as thumbnail URLs', () {
    final wallpaper = FirebaseWallpaper.fromJson('video-2', {
      'name': 'Night Drive',
      'type': 'video',
      'url': 'https://cdn.example.net/wallpapers/night-drive.mp4',
      'thumbnailUrl': 'https://cdn.example.net/wallpapers/night-drive.mp4',
    });

    expect(wallpaper.url, endsWith('.mp4'));
    expect(wallpaper.thumbnailUrl, isNull);
    expect(
      FirebaseWallpaper.isValidThumbnailUrl(
        'https://cdn.example.net/wallpapers/night-drive.mp4',
      ),
      isFalse,
    );
    expect(
      FirebaseWallpaper.isValidThumbnailUrl(
        'https://cdn.example.net/wallpapers/night-drive.mp4?alt=media&token=xyz',
      ),
      isFalse,
    );
    expect(
      FirebaseWallpaper.isValidThumbnailUrl(
        'https://cdn.example.net/wallpapers/thumb.jpg?alt=media&token=xyz',
      ),
      isTrue,
    );
  });

  test(
    'reserved example.com catalog URLs are rejected without replacements',
    () {
      final wallpaper = FirebaseWallpaper.fromJson('test-edit', {
        'name': 'Edited Wallpaper Title',
        'type': 'video',
        'url': 'https://assets.example.com/videos/edited.mp4',
        'thumbnailUrl': 'https://assets.example.com/videos/edited.jpg',
      });

      expect(wallpaper.hasUsableSource, isFalse);
      expect(wallpaper.thumbnailUrl, isNull);
    },
  );

  test('valid poster image URLs remain separate from the video source', () {
    final wallpaper = FirebaseWallpaper.fromJson('video-3', {
      'name': 'Aurora',
      'type': 'video',
      'url': 'https://cdn.example.net/video/aurora.mp4',
      'thumbnailUrl': 'https://cdn.example.net/images/aurora.jpg',
    });

    expect(wallpaper.url, endsWith('.mp4'));
    expect(wallpaper.thumbnailUrl, endsWith('.jpg'));
  });

  test(
    'cache candidates are valid only while their files are non-empty',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'wallsync-cache-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(
        '${directory.path}${Platform.pathSeparator}wallpaper.png',
      );

      expect(await FirebaseService.isCachedWallpaperFileValid(file), isFalse);
      await file.writeAsBytes([]);
      expect(await FirebaseService.isCachedWallpaperFileValid(file), isFalse);
      await file.writeAsBytes([1, 2, 3]);
      expect(await FirebaseService.isCachedWallpaperFileValid(file), isTrue);
    },
  );

  test('FirebaseWallpaper correctly parses and serializes isPro', () {
    final proWallpaper = FirebaseWallpaper.fromJson('pro-1', {
      'name': 'Neon Cyberpunk Pro',
      'category': 'Cyberpunk',
      'type': 'video',
      'url': 'https://res.cloudinary.com/demo/video/upload/cyber.mp4',
      'isPro': true,
    });

    expect(proWallpaper.isPro, isTrue);
    expect(proWallpaper.toJson()['isPro'], isTrue);

    final standardWallpaper = FirebaseWallpaper.fromJson('free-1', {
      'name': 'Nature Sunset',
      'category': 'Nature',
      'type': 'static',
      'url': 'https://cdn.example.com/sunset.jpg',
    });

    expect(standardWallpaper.isPro, isFalse);
    expect(standardWallpaper.toJson()['isPro'], isFalse);

    // Also support 'pro: true' alias
    final aliasProWallpaper = FirebaseWallpaper.fromJson('pro-2', {
      'name': 'Gold Star Pro',
      'category': 'Abstract',
      'type': 'static',
      'url': 'https://cdn.example.com/star.jpg',
      'pro': true,
    });

    expect(aliasProWallpaper.isPro, isTrue);
  });
}
