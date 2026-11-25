#if Architecture == "x64"
  #define WinArchitecture "x64os"
  #define SetupBinary "x64"
#elif Architecture == "arm64"
  #define WinArchitecture "arm64"
  #define SetupBinary "x86"
#else
  #error Unsupported Luqri architecture
#endif

[Setup]
AppId={{9A384458-00F3-47D6-B675-ADDB4DD28B28}
AppName=Luqri
AppVersion={#Version}
AppPublisher=Luqri
DefaultDirName={localappdata}\Programs\Luqri
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
SetupArchitecture={#SetupBinary}
ArchitecturesAllowed={#WinArchitecture}
ArchitecturesInstallIn64BitMode={#WinArchitecture}
MinVersion=10.0.14393
SetupIconFile=Luqri.ico
UninstallDisplayName=Luqri
UninstallDisplayIcon={app}\Luqri.exe
VersionInfoVersion={#Version}.0
VersionInfoProductName=Luqri
VersionInfoDescription=Luqri Setup
WizardStyle=modern
OutputBaseFilename=Luqri-Setup-{#Architecture}
Compression=none

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Excludes: "*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Luqri"; Filename: "{app}\Luqri.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\Luqri.exe"; Description: "{cm:LaunchProgram,Luqri}"; Flags: nowait postinstall skipifsilent
