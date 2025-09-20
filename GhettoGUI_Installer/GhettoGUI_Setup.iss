; Inno Setup Skript für GhettoGUI
; Version 1.3.3 - Prototyp-Fehler in [Code] Sektion korrigiert
; Erstellt von Gemini & Chrigel#71

[Setup]
AppId={{FC81AEAD-C671-4204-AED4-93C696FA88E2}} ; Behalte deine neue ID bei
AppName=GhettoGUI ESXi Manager
AppVersion=7.5.0
AppPublisher=Gemini & Chrigel#71
DefaultDirName={pf}\GhettoGUI
DefaultGroupName=GhettoGUI
DisableProgramGroupPage=yes
SetupIconFile=SourceFiles\GhettoGUI.ico
OutputDir=Release
OutputBaseFilename=GhettoGUI-Setup-V7.5.0
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
Source: "SourceFiles\*.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\*.py"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\*.sh"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\*.html"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\*.cer"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\*.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\ndp48-x86-x64-allos-enu.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "SourceFiles\Win7AndW2K8R2-KB3191566-x64.msu"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
Name: "{group}\GhettoGUI ESXi Manager"; Filename: "{app}\GhettoGUI.exe"
Name: "{group}\{cm:UninstallProgram,GhettoGUI}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\GhettoGUI ESXi Manager"; Filename: "{app}\GhettoGUI.exe"; Tasks: desktopicon

[Run]
Filename: "powershell.exe"; \
    Parameters: "-ExecutionPolicy Bypass -NoProfile -Command ""if (-not (Get-Module -Name Posh-SSH -ListAvailable)) {{ Install-Module -Name Posh-SSH -Scope CurrentUser -Force -Confirm:$false }}"""; \
    StatusMsg: "Prüfe und installiere Posh-SSH PowerShell Modul..."; \
    Flags: runhidden shellexec waituntilterminated

Filename: "certutil.exe"; \
    Parameters: "-addstore ""TrustedPublishers"" ""{app}\GhettoGUIScripts_public.cer"""; \
    StatusMsg: "Installiere Code-Signing Zertifikat..."; \
    Flags: runhidden waituntilterminated

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
var
  NeedsNet48: Boolean;
  NeedsWmf51: Boolean;

// Funktion zum Prüfen, ob .NET 4.8 (oder neuer) installiert ist
function IsNet48OrNewerInstalled: Boolean;
var
  NetVersion: Cardinal;
begin
  Result := RegQueryDWordValue(HKLM, 'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full', 'Release', NetVersion);
  if Result then
    Result := (NetVersion >= 528040)
end;

// Funktion zum Prüfen, ob PowerShell 5.1 (oder neuer) installiert ist
function IsPowerShell51OrNewerInstalled: Boolean;
var
  PSVersion: String;
begin
  Result := RegQueryStringValue(HKLM, 'SOFTWARE\Microsoft\PowerShell\3\PowerShellEngine', 'PowerShellVersion', PSVersion);
  if Result then
    Result := (CompareStr(PSVersion, '5.1') >= 0);
end;

// Diese Funktion wird ganz am Anfang des Setups ausgeführt
// ### KORREKTUR 1: Deklaration von 'procedure' zu 'function' geändert ###
function InitializeSetup(): Boolean;
var
  WinVersion: TWindowsVersion;
begin
  GetWindowsVersionEx(WinVersion);
  
  // Wir müssen nur auf Windows 7 prüfen
  if (WinVersion.Major = 6) and (WinVersion.Minor = 1) then
  begin
    Log('System ist Windows 7. Prüfe Voraussetzungen...');
    NeedsNet48 := not IsNet48OrNewerInstalled;
    NeedsWmf51 := not IsPowerShell51OrNewerInstalled;
  end
  else
  begin
    Log('System ist neuer als Windows 7. Keine besonderen Prüfungen nötig.');
    NeedsNet48 := False;
    NeedsWmf51 := False;
  end;
  
  // ### KORREKTUR 2: Rückgabewert hinzugefügt ###
  Result := True;
end;

// Diese Funktion wird aufgerufen, bevor die eigentliche Installation (Dateien kopieren) beginnt
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  // Schritt 1: Installiere .NET 4.8, falls nötig
  if NeedsNet48 then
  begin
    if MsgBox('Für GhettoGUI wird .NET Framework 4.8 benötigt. Dies kann einige Minuten dauern. Möchten Sie es jetzt installieren?', mbConfirmation, MB_YESNO) = IDYES then
    begin
      ExtractTemporaryFile('ndp48-x86-x64-allos-enu.exe');
      WizardForm.StatusLabel.Caption := 'Installiere .NET Framework 4.8... Bitte warten, dies kann einige Minuten dauern.';
      WizardForm.ProgressGauge.Style := npbstMarquee;
      if Exec(ExpandConstant('{tmp}\ndp48-x86-x64-allos-enu.exe'), '/q /norestart', '', SW_SHOW, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0) then
      begin
        Log('.NET 4.8 erfolgreich installiert.');
        NeedsRestart := True;
      end
      else
      begin
        MsgBox('.NET 4.8 konnte nicht installiert werden. Setup wird abgebrochen.', mbError, MB_OK);
        Result := 'Installation von .NET 4.8 fehlgeschlagen.';
        exit;
      end;
    end
    else
    begin
      Result := 'Benutzer hat .NET 4.8 Installation abgelehnt.';
      exit;
    end;
  end;

  // Schritt 2: Installiere WMF 5.1, falls nötig
  if NeedsWmf51 then
  begin
    if MsgBox('Für GhettoGUI wird PowerShell 5.1 (WMF 5.1) benötigt. Möchten Sie es jetzt installieren?', mbConfirmation, MB_YESNO) = IDYES then
    begin
      ExtractTemporaryFile('Win7AndW2K8R2-KB3191566-x64.msu');
      WizardForm.StatusLabel.Caption := 'Installiere Windows Management Framework 5.1...';
      WizardForm.ProgressGauge.Style := npbstMarquee;
      if Exec('wusa.exe', ExpandConstant('"{tmp}\Win7AndW2K8R2-KB3191566-x64.msu" /quiet /norestart'), '', SW_SHOW, ewWaitUntilTerminated, ResultCode) and ((ResultCode = 0) or (ResultCode = 3010)) then
      begin
        Log('WMF 5.1 erfolgreich installiert. ResultCode: ' + IntToStr(ResultCode));
        NeedsRestart := True;
      end
      else
      begin
        MsgBox('WMF 5.1 konnte nicht installiert werden. Setup wird abgebrochen.', mbError, MB_OK);
        Result := 'Installation von WMF 5.1 fehlgeschlagen. ResultCode: ' + IntToStr(ResultCode);
        exit;
      end;
    end
    else
    begin
      Result := 'Benutzer hat WMF 5.1 Installation abgelehnt.';
      exit;
    end;
  end;
end;