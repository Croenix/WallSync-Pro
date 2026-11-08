# WallSync

WallSync is a Windows desktop wallpaper and widget application.

## Getting Started

See the [Flutter documentation](https://docs.flutter.dev/) for help building
and running the desktop application.

## Live video wallpapers

The wallpaper process plays local video files through WebView2, using its
Windows video decoding path and HTML looping. Its isolated
`LiveWallpaperManager` service exposes play, pause, stop, volume, and mute
controls. The Windows runner's native MethodChannel plugin attaches the
wallpaper window behind desktop icons and pauses playback while another app is
fullscreen or Windows Battery Saver is active.

The video wallpaper source panel can also fetch YouTube video details, select
a segment up to 60 seconds, and save the trimmed clip locally for offline
playback. It selects the highest available adaptive video stream (up to 8K
when the source provides it), downloads a matching audio stream, and remuxes
both without re-encoding. The combined source streams and final clip are each
limited to 95 MB. Since source streams are downloaded before trimming, a short
selected segment may be unavailable when its complete streams exceed this cap.
Playback depends on the codecs supported by the Windows video decoder. YouTube
may temporarily rate-limit requests from a network; if that happens, wait
before trying again. Only save videos you have permission to use.

The FFmpeg Windows runtime is staged during the Flutter native-assets build.
Keep the checkout path short (for example, `C:\src\WallSync-Pro`) to avoid
Windows path-length issues while extracting the runtime.

The desktop-window discovery and raised-desktop attachment behavior is adapted
from [Lively Wallpaper](https://github.com/lively-community/lively), specifically
`WinDesktopCore.cs` and `DesktopUtil.cs` at revision
`25a0a5f4ed1988ff42117d3a17feb321062237fe` (GPL-3.0; license text in
`LICENSES/LIVELY-GPL-3.0.txt`). Lively's player embeds a native WebView2 window;
WallSync keeps its Flutter/WebView2 renderer and moves the Flutter view HWND,
rather than copying Lively's player application. Distributions containing this
derived native attachment code must comply with GPL-3.0.

## Windows taskbar and dock

The Taskbar Studio can run the WallSync dock alongside Windows or replace the
primary taskbar with a full-width, app-owned native window. Windows does not
provide a supported API for skinning Explorer's taskbar in place. Replacement
aligns the WallSync HWND to the native taskbar's measured bounds, verifies its
PID, visibility, position and readiness handshake, and only then hides the
native taskbar. Startup or positioning failures restore Windows. Replacement
currently refuses to hide taskbars on secondary displays or replace a vertical
taskbar until a corresponding replacement window is available for each display.

The replacement bar includes Windows Search, Task View, File Explorer, Copilot,
running-window activation, quick settings, Wi-Fi/audio/power settings,
notifications, and show-desktop actions. These invoke Windows shell commands,
settings pages, or keyboard shortcuts; they do not embed Explorer's private
system-tray UI. Pinned apps and custom actions open the configured Windows app,
file, or website. Configure those launch targets in Desktop Studio's Components
pane. The running-app section uses native Win32 window enumeration and
activation. Dock activation is acknowledged only after the child process
confirms its instance, operation and configuration revision, publishes its own
HWND, and signals the named readiness event; the parent then verifies the HWND
owner PID, visibility, monitor bounds and IPC signal.

The Windows runner records early native startup stages and Dart bootstrap
stages in a separate file per process under
`%APPDATA%\com.example\wallsync\diagnostics`. Filenames include the PID,
startup timestamp, process mode, instance ID and operation ID. The parent
captures child stdout/stderr and records the child log path in the per-instance
PID record.

## Admin panel setup

The admin panel uses Firebase Authentication and the `adminApi` Cloud Function.
Cloudinary credentials must only be configured as Firebase Function secrets; do
not put them in the panel or Realtime Database.

1. In Firebase Authentication, enable Email/Password and create the administrator
   accounts. Add each administrator's Firebase Auth UID to the `ADMIN_UIDS`
   function parameter. For this project, deployment parameters can be kept in
   the git-ignored `functions/.env.wallsync-e043c` file. Realtime Database
   report access is restricted to the configured administrator UID.
2. Copy `admin_panel/firebase-config.example.js` to
   `admin_panel/firebase-config.js` and set its public Web API key from the
   Firebase Console. The local config file is git-ignored.
3. Install the Functions dependencies by running `npm install` from `functions`.
4. Set the Cloudinary Function secrets:
   ```powershell
   firebase functions:secrets:set CLOUDINARY_API_KEY --project wallsync-e043c
   firebase functions:secrets:set CLOUDINARY_API_SECRET --project wallsync-e043c
   ```
   Configure `CLOUDINARY_CLOUD_NAME`, `ADMIN_UIDS`, and `ADMIN_ORIGINS` in the
   project-specific Functions environment file or when prompted at deployment.
5. Deploy the database rules and function with
   `firebase deploy --project wallsync-e043c --only database,functions`.
6. `ADMIN_ORIGINS` defaults to the local panel origins on ports 3000 and 8000.
   If serving the panel elsewhere, set it to the exact origin, then serve
   `admin_panel` over HTTP. Do not open the panel using a `file://` URL.

The Admin Panel server loads `admin_panel/.env` automatically when it starts.
Copy `admin_panel/.env.example` to create a settings template. Set `PORT`,
`HOST`, `PUBLIC_SERVER_URL`, `FIREBASE_RTDB_URL`, and `FIREBASE_WEB_API_KEY` as
needed; optional Cloudinary settings are also supported. When set, the server
uses the Web API key to provide Firebase Authentication configuration to the
browser. The actual `.env` file is git-ignored. Alternatively, provide
`admin_panel/firebase-config.js` as described above.

New user reports are written to `/reports`; older submissions may remain under
`/bugs`. The Admin Panel reads and manages both paths. Clients can create
reports, while reading and deleting reports requires the configured Firebase
administrator account.

If Cloudinary credentials were previously saved under `/config/cloudinary`, rotate
the Cloudinary API secret in Cloudinary and remove the old database value. The
Realtime Database rules in `database.rules.json` deny client access to that path.
