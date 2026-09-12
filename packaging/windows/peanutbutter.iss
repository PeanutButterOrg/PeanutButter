; PeanutButter Windows installer (Inno Setup 6)
; Paths are relative to this .iss file unless overridden with /DMyApp* defines.
#define MyAppName "PeanutButter"
#define MyAppVersion "0.2.0"
#define MyAppPublisher "PeanutButter"
#define MyAppExeName "peanutbutter.exe"
#ifndef MyAppSource
  #define MyAppSource "..\..\frontend\build\windows\x64\runner\Release"
#endif
#ifndef MyAppOutputDir
  #define MyAppOutputDir "..\..\frontend\dist"
#endif
#ifndef MyAppIcon
  #define MyAppIcon "..\..\frontend\windows\runner\resources\app_icon.ico"
#endif

[Setup]
AppId={{A7C2E9F1-4B6D-4E8A-9C1F-2D3E4F5A6B7C}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#MyAppOutputDir}
OutputBaseFilename=PeanutButter-windows-x64-setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile={#MyAppIcon}
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#MyAppSource}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
