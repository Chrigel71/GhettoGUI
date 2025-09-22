; Inno Setup Skript für GhettoGUI
; Version 5.1.0 - Finale Version mit erzwungener Neustart-Abfrage
; Erstellt von Gemini & Chrigel#71

[Setup]
AppId={{FC81AEAD-C671-4204-AED4-93C696FA88E2}}
AppName=GhettoGUI ESXi Manager
AppVersion=7.5.0.0
AppPublisher=Gemini & Chrigel#71
DefaultDirName={pf}\GhettoGUI
DefaultGroupName=GhettoGUI
DisableProgramGroupPage=yes
SetupIconFile=SourceFiles\GhettoGUI.ico
OutputDir=Release
OutputBaseFilename=GhettoGUI-Setup-V7.5.0.0
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin

[Languages]
Name: "german"; MessagesFile: "compiler:Languages\German.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}";

[Files]
Source: "SourceFiles\GhettoGUI.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\*.py"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\*.sh"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\*.html"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\GhettoGUIScripts_public.cer"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\*.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\*.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\*.zip"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\ndp48-x86-x64-allos-enu.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "SourceFiles\Win7AndW2K8R2-KB3191566-x64.msu"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
Name: "{group}\GhettoGUI ESXi Manager"; Filename: "{app}\GhettoGUI.exe"
Name: "{group}\{cm:UninstallProgram,GhettoGUI}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\GhettoGUI ESXi Manager"; Filename: "{app}\GhettoGUI.exe"; Tasks: desktopicon

[Run]
; Führt alle Installationen nacheinander aus.
Filename: "{tmp}\ndp48-x86-x64-allos-enu.exe"; Parameters: "/passive /norestart"; Description: "Installiere .NET Framework 4.8..."; Flags: waituntilterminated
Filename: "wusa.exe"; Parameters: """{tmp}\Win7AndW2K8R2-KB3191566-x64.msu"" /quiet /norestart"; Description: "Installiere PowerShell 5.1..."; Flags: waituntilterminated
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -NoProfile -Command ""if (-not (Get-Module -Name Posh-SSH -ListAvailable)) {{ Install-Module -Name Posh-SSH -Scope CurrentUser -Force -Confirm:$false }}"""; Description: "Installiere PowerShell Modul Posh-SSH..."; Flags: runhidden shellexec waituntilterminated

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[UninstallRun]
Filename: "powershell.exe"; \
    Parameters: "-Command ""Set-ExecutionPolicy RemoteSigned -Force -Scope LocalMachine"""; \
    Flags: runhidden

[Code]
// Diese Funktion wird aufgerufen, nachdem alle Dateien kopiert wurden.
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  Msg: String;
  CommandToCopy: String;
begin
  if CurStep = ssPostInstall then
  begin
    CommandToCopy := 'Set-ExecutionPolicy Unrestricted -Force';
    Exec('powershell.exe', '-Command "Set-Clipboard -Value ''' + CommandToCopy + '''"', '', SW_HIDE, ewNoWait, ResultCode);
    Msg := 'Die Installation ist fast abgeschlossen.' + #13#10 + #13#10 +
           'ZWEI LETZTE SCHRITTE SIND NÖTIG:' + #13#10 + #13#10 +
           '1. ZERTIFIKAT: Im nächsten Fenster das Zertifikat installieren...' + #13#10 + #13#10 +
           '2. POWERSHELL: Im PowerShell-Fenster, das DANACH erscheint, den Befehl mit einem RECHTSKLICK einfügen und Enter drücken...' + #13#10 + #13#10 +
           'Befehl: ' + CommandToCopy;
    MsgBox(Msg, mbInformation, MB_OK);
    ShellExec('open', ExpandConstant('{app}\GhettoGUIScripts_public.cer'), '', '', SW_SHOW, ewWaitUntilTerminated, ResultCode);
    Exec('powershell.exe', '', '', SW_SHOW, ewWaitUntilTerminated, ResultCode);

    // ### FINALE LÖSUNG: Eigene, unbedingte Neustart-Abfrage ###
    if MsgBox('Ein Neustart wird empfohlen, um die Installation abzuschließen. Möchten Sie den Computer jetzt neu starten?', mbConfirmation, MB_YESNO) = IDYES then
    begin
      Exec('shutdown.exe', '/r /t 15 /c "GhettoGUI Setup erfordert einen Neustart."', '', SW_HIDE, ewNoWait, ResultCode);
    end;
  end;
end;