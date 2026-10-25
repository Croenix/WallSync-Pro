[Setup]
AppId={{5F7A348D-85B4-4B7C-8A6B-9D0E40A56C42}
AppName=WallSync Pro
AppVersion=1.0.0.0.1
AppPublisher=RedSkill Studios
DefaultDirName={autopf}\WallSync Pro
DisableProgramGroupPage=yes
OutputDir=Output
OutputBaseFilename=WallSyncPro_Installer
Compression=lzma
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\unins000.exe
SetupIconFile=windows\runner\resources\app_icon.ico

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
Name: "{autoprograms}\WallSync Pro"; Filename: "{app}\WallSync.exe"
Name: "{autodesktop}\WallSync Pro"; Filename: "{app}\WallSync.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\WallSync.exe"; Parameters: "--sync-startup-registration"; WorkingDir: "{app}"; Flags: runasoriginaluser runhidden waituntilterminated
Filename: "{app}\WallSync.exe"; Description: "{cm:LaunchProgram,WallSync Pro}"; Flags: runasoriginaluser nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /F /TN ""\WallSyncOverlayStartup"""; Flags: runhidden
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /F /TN ""DesktopWidgetOverlayLaunch"""; Flags: runhidden
Filename: "{sys}\reg.exe"; Parameters: "delete ""HKCU\Software\Microsoft\Windows\CurrentVersion\Run"" /v WallSync /f"; Flags: runhidden
Filename: "{sys}\reg.exe"; Parameters: "delete ""HKCU\Software\Microsoft\Windows\CurrentVersion\Run"" /v DesktopWidgetOverlay /f"; Flags: runhidden
