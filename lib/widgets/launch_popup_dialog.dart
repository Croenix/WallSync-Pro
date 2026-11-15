import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/launch_popup_service.dart';

/// Interactive promotional poster dialog shown on app launch.
///
/// Features:
/// 1. Close button on the top-right of the image to dismiss.
/// 2. Primary Action Button ("Continue") with custom text & URL redirect to browser.
/// 3. Dark glassmorphic modern styling matching WallSync aesthetics.
class LaunchPopupDialog extends StatelessWidget {
  final LaunchPopupConfig config;

  const LaunchPopupDialog({super.key, required this.config});

  Uri? get _actionUri {
    final uri = Uri.tryParse(config.actionUrl.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri;
  }

  bool get _hasActionUrl => _actionUri != null;

  Future<void> _onActionPressed(BuildContext context) async {
    Navigator.of(context).pop();
    final uri = _actionUri;
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final dialogWidth = screenSize.width.clamp(300.0, 420.0);
    final maxDialogHeight = screenSize.height * 0.82;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: dialogWidth,
          constraints: BoxConstraints(maxHeight: maxDialogHeight),
          margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          decoration: BoxDecoration(
            color: const Color(0xFF131625).withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.65),
                blurRadius: 36,
                spreadRadius: 4,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Top Poster Image with Floating Close Button (X)
                Flexible(
                  child: Stack(
                    children: [
                      // Poster Image
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          minHeight: 200,
                          maxHeight: 460,
                        ),
                        child: Container(
                          width: double.infinity,
                          color: const Color(0xFF0A0C14),
                          child: Image.network(
                            config.imageUrl,
                            fit: BoxFit.cover,
                            // Bound decode dimensions: prevents full-res RGBA decode into GPU texture.
                            // A 420px-wide dialog does not benefit from > 840px source decode.
                            cacheWidth: 840,
                            cacheHeight: 1000,
                            loadingBuilder: (context, child, loadingProgress) {
                              if (loadingProgress == null) return child;
                              return Container(
                                height: 260,
                                alignment: Alignment.center,
                                child: CircularProgressIndicator(
                                  value:
                                      loadingProgress.expectedTotalBytes != null
                                      ? loadingProgress.cumulativeBytesLoaded /
                                            loadingProgress.expectedTotalBytes!
                                      : null,
                                  strokeWidth: 2.5,
                                  color: const Color(0xFF38BDF8),
                                ),
                              );
                            },
                            errorBuilder: (context, error, stackTrace) {
                              return Container(
                                height: 240,
                                padding: const EdgeInsets.all(24),
                                alignment: Alignment.center,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.broken_image_rounded,
                                      size: 48,
                                      color: Colors.white.withValues(
                                        alpha: 0.4,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Poster unavailable',
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.6,
                                        ),
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),

                      // Floating Top-Right Close Button (X)
                      Positioned(
                        top: 12,
                        right: 12,
                        child: ClipOval(
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                            child: Material(
                              color: Colors.black.withValues(alpha: 0.6),
                              shape: const CircleBorder(
                                side: BorderSide(
                                  color: Colors.white24,
                                  width: 1,
                                ),
                              ),
                              child: InkWell(
                                onTap: () => Navigator.of(context).pop(),
                                child: const SizedBox(
                                  width: 36,
                                  height: 36,
                                  child: Icon(
                                    Icons.close_rounded,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Bottom Action Button Row
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 16,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF131625),
                    border: Border(
                      top: BorderSide(
                        color: Colors.white.withValues(alpha: 0.08),
                        width: 1,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF38BDF8), Color(0xFF2563EB)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(
                                  0xFF2563EB,
                                ).withValues(alpha: 0.35),
                                blurRadius: 14,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: ElevatedButton(
                            onPressed: () => _onActionPressed(context),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              shadowColor: Colors.transparent,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  !_hasActionUrl
                                      ? 'Close'
                                      : config.actionText.isNotEmpty
                                      ? config.actionText
                                      : 'Continue',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.3,
                                  ),
                                ),
                                if (_hasActionUrl) ...[
                                  const SizedBox(width: 6),
                                  const Icon(
                                    Icons.open_in_new_rounded,
                                    size: 16,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
