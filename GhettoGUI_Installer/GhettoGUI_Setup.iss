; Inno Setup Skript für GhettoGUI
; Erstellt von Gemini & Chrigel#71
; Version 1.2 - Fügt Zertifikatsinstallation hinzu

[Setup]
; Eindeutige ID für die Anwendung. Wichtig für die Deinstallation.
AppId={{C1E9A55C-4B1C-4E1F-8D7A-5B671B8E2F3F}}
AppName=GhettoGUI ESXi Manager
AppVersion=7.5.0
AppPublisher=Gemini & Chrigel#71
; Standardpfad ist jetzt C:\Programme\GhettoGUI
DefaultDirName={pf}\GhettoGUI
DefaultGroupName=GhettoGUI
DisableProgramGroupPage=yes
; Definiert das Icon für den Installer und die Deinstallation
SetupIconFile=SourceFiles\bowserpound.ico
; Ort und Name der fertigen Setup-Datei
OutputDir=Release
OutputBaseFilename=GhettoGUI-Setup-V7.5.0
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; Fordert Administratorrechte an, die für die Installation in C:\Programme und für das Zertifikat benötigt werden
PrivilegesRequired=admin

[Languages]
Name: "german"; MessagesFile: "compiler:Languages\German.isl"

[Tasks]
; Ermöglicht dem Benutzer, eine Desktop-Verknüpfung zu erstellen
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}";

[Files]
; Hier listen wir alle Dateien auf, die installiert werden sollen.
Source: "SourceFiles\GhettoGUI.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\GhettoGUI_V7.5.0.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\sendmail.py"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\ghettoVCB_patch.sh"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\Index.html"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\GhettoGUIScripts_public.cer"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\192.168.1.35-Job-MUSTER.json"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; Erstellt die Einträge im Startmenü und optional auf dem Desktop
Name: "{group}\GhettoGUI ESXi Manager"; Filename: "{app}\GhettoGUI.exe"
Name: "{group}\{cm:UninstallProgram,GhettoGUI}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\GhettoGUI ESXi Manager"; Filename: "{app}\GhettoGUI.exe"; Tasks: desktopicon

[Run]
; Schritt 1: Posh-SSH Modul installieren
Filename: "powershell.exe"; \
    Parameters: "-ExecutionPolicy Bypass -NoProfile -Command ""if (-not (Get-Module -Name Posh-SSH -ListAvailable)) {{ Install-Module -Name Posh-SSH -Scope CurrentUser -Force -Confirm:$false }}"""; \
    StatusMsg: "Prüfe und installiere Posh-SSH PowerShell Modul..."; \
    Flags: runhidden shellexec waituntilterminated

; Schritt 2 (NEU): Code-Signing Zertifikat in den Speicher für "Vertrauenswürdige Herausgeber" importieren
Filename: "certutil.exe"; \
    Parameters: "-addstore ""TrustedPublishers"" ""{app}\GhettoGUIScripts_public.cer"""; \
    StatusMsg: "Installiere Code-Signing Zertifikat..."; \
    Flags: runhidden waituntilterminated

[UninstallDelete]
; Definiert, welche Dateien und Ordner bei der Deinstallation entfernt werden sollen
Type: filesandordirs; Name: "{app}"