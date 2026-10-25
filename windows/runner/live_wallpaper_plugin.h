#ifndef RUNNER_LIVE_WALLPAPER_PLUGIN_H_
#define RUNNER_LIVE_WALLPAPER_PLUGIN_H_

#include <memory>

namespace flutter {
class PluginRegistrarWindows;
}  // namespace flutter

class LiveWallpaperPlugin {
 public:
  explicit LiveWallpaperPlugin(flutter::PluginRegistrarWindows* registrar);
  ~LiveWallpaperPlugin();

  LiveWallpaperPlugin(const LiveWallpaperPlugin&) = delete;
  LiveWallpaperPlugin& operator=(const LiveWallpaperPlugin&) = delete;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_LIVE_WALLPAPER_PLUGIN_H_
