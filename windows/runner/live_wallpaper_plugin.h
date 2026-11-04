#ifndef RUNNER_LIVE_WALLPAPER_PLUGIN_H_
#define RUNNER_LIVE_WALLPAPER_PLUGIN_H_

#include <functional>
#include <memory>

namespace flutter {
class PluginRegistrarWindows;
}  // namespace flutter

class LiveWallpaperPlugin {
 public:
  LiveWallpaperPlugin(flutter::PluginRegistrarWindows* registrar,
                      std::function<void()> force_redraw);
  ~LiveWallpaperPlugin();

  LiveWallpaperPlugin(const LiveWallpaperPlugin&) = delete;
  LiveWallpaperPlugin& operator=(const LiveWallpaperPlugin&) = delete;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_LIVE_WALLPAPER_PLUGIN_H_
