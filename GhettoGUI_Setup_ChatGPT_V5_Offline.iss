; Inno Setup 6.5.3 Script - GhettoGUI Hybrid Prereq Download (V23)
; - Keep setup small: no .NET/MSU bundled
; - Hybrid: use prereq file next to Setup EXE if present, else download from HTTPS
; - Win7 minimal support (1-3 machines): install KB3033929 (SHA256) + WMF5.1 + .NET4.8 only if needed
; - App is compiled EXE (no PS2EXE).

[Setup]
AppId={{FC81AEAD-C671-4204-AED4-93C696FA88E2}}
AppName=GhettoGUI ESXi & Proxmox Manager
AppVersion=8.8.3
AppPublisher=Chrigel#71
DefaultDirName={pf}\GhettoGUI
DefaultGroupName=GhettoGUI
DisableProgramGroupPage=yes
SetupIconFile=SourceFiles\GhettoGUI.ico
OutputDir=Release
OutputBaseFilename=GhettoGUI-Setup-V8.8.3_Offline
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
UninstallDisplayIcon={app}\GhettoGUI.exe

[Languages]
Name: "german"; MessagesFile: "compiler:Languages\German.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; --- App payload ---
Source: "SourceFiles\GhettoGUI.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\sendmail.py"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\ghettoVCB_patch.sh"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\Index.html"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\Bedienungsanleitung.html"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\*.png"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\*.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\*.zip"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\*.*"; DestDir: "{app}"; Flags: ignoreversion

; --- WinSCP (big file allowed) ---
Source: "SourceFiles\WinSCP.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\WinSCPnet.dll"; DestDir: "{app}"; Flags: ignoreversion

Source: "SourceFiles\GhettoGUI.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\GhettoStart.bat"; DestDir: "{app}"; Flags: ignoreversion

; --- Certificates ---
Source: "SourceFiles\GhettoGUIScripts_public.cer"; DestDir: "{app}"; Flags: ignoreversion
Source: "SourceFiles\GhettoGUIInstaller_public.cer"; DestDir: "{app}"; Flags: ignoreversion

; --- Modules (Posh-SSH) - offline, system-wide so PowerShell finds it automatically ---
Source: "SourceFiles\Modules\Posh-SSH\*"; DestDir: "{commonappdata}\WindowsPowerShell\Modules\Posh-SSH"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\GhettoGUI"; Filename: "{app}\GhettoGUI.exe"
Name: "{group}\Bedienungsanleitung"; Filename: "{app}\Bedienungsanleitung.html"
Name: "{group}\Startseite (Index)"; Filename: "{app}\Index.html"
Name: "{group}\{cm:UninstallProgram,GhettoGUI}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\GhettoGUI"; Filename: "{app}\GhettoGUI.exe"; Tasks: desktopicon

[Dirs]
; If you keep writable JSON/jobs under {app}, users need write permissions.
; Long-term recommended: move writable data to {commonappdata}\GhettoGUI, but we keep your current behavior.
Name: "{app}"; Permissions: users-modify

[Run]
; --- Silent trust setup (cert import) ---
Filename: "certutil.exe"; Parameters: "-addstore -f ""TrustedPublisher"" ""{app}\GhettoGUIScripts_public.cer"""; Flags: runhidden waituntilterminated
Filename: "certutil.exe"; Parameters: "-addstore -f ""Root"" ""{app}\GhettoGUIScripts_public.cer"""; Flags: runhidden waituntilterminated
Filename: "certutil.exe"; Parameters: "-addstore -f ""TrustedPublisher"" ""{app}\GhettoGUIInstaller_public.cer"""; Flags: runhidden waituntilterminated
Filename: "certutil.exe"; Parameters: "-addstore -f ""Root"" ""{app}\GhettoGUIInstaller_public.cer"""; Flags: runhidden waituntilterminated

; --- Execution policy (conservative) ---
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force | Out-Null"""; \
  Flags: runhidden waituntilterminated

; --- Start app (optional) ---
Filename: "{app}\GhettoGUI.exe"; Description: "GhettoGUI starten"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
const
  DotNet48FileName   = 'NDP48-x86-x64-AllOS-ENU.exe';
  DotNet48Url        = 'https://files.drucksprint.ch/Ghetto/NDP48-x86-x64-AllOS-ENU.exe';

  KB3033929FileName  = 'windows6.1_W7_kb3033929-x64.msu';
  KB3033929Url       = 'https://files.drucksprint.ch/Ghetto/windows6.1_W7_kb3033929-x64.msu';

  WMF51FileName      = 'Win7AndW2K8R2-KB3191566-x64.msu';
  WMF51Url           = 'https://files.drucksprint.ch/Ghetto/Win7AndW2K8R2-KB3191566-x64.msu';

var
  NeedRestart: Boolean;

function URLDownloadToFileW(pCaller: Integer; szURL: WideString; szFileName: WideString; dwReserved: Integer; lpfnCB: Integer): Integer;
  external 'URLDownloadToFileW@urlmon.dll stdcall';

function IsWin7Or2008R2: Boolean;
begin
  Result := (GetWindowsVersion >= $06010000) and (GetWindowsVersion < $06020000);
end;

function NeedsDotNet48: Boolean;
var
Release: Cardinal;
begin
  Result := True;
  if RegQueryDWordValue(HKLM, 'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full', 'Release', Release) then
  begin
    // .NET 4.8 Release >= 528040
    if Release >= 528040 then Result := False;
  end;
end;

procedure ParseMajorMinor(const Ver: string; var Major, Minor: Integer);
var
  p: Integer;
  sMajor, sMinor, tmp: string;
begin
  Major := 0; Minor := 0;

  tmp := Ver;
  p := Pos('.', tmp);
  if p = 0 then begin Major := StrToIntDef(tmp, 0); Exit; end;

  sMajor := Copy(tmp, 1, p-1);
  tmp := Copy(tmp, p+1, Length(tmp));

  p := Pos('.', tmp);
  if p = 0 then sMinor := tmp else sMinor := Copy(tmp, 1, p-1);

  Major := StrToIntDef(sMajor, 0);
  Minor := StrToIntDef(sMinor, 0);
end;

function GetInstalledPowerShellVersion(var Ver: string): Boolean;
begin
  Result := RegQueryStringValue(HKLM, 'SOFTWARE\Microsoft\PowerShell\3\PowerShellEngine', 'PowerShellVersion', Ver);
  if not Result then
    Result := RegQueryStringValue(HKLM, 'SOFTWARE\Microsoft\PowerShell\1\PowerShellEngine', 'PowerShellVersion', Ver);
end;

function NeedsWMF51: Boolean;
var
  Ver: string;
  Major, Minor: Integer;
begin
  Result := False;

  // WMF 5.1 package only relevant for Win7/2008R2
  if not IsWin7Or2008R2 then Exit;

  if GetInstalledPowerShellVersion(Ver) then
  begin
    ParseMajorMinor(Ver, Major, Minor);
    if (Major < 5) or ((Major = 5) and (Minor < 1)) then
      Result := True;
  end
  else
  begin
    Result := True;
  end;
end;

function HasKB3033929: Boolean;
begin
  // best-effort detection via CBS package keys (common variants)
  Result :=
    RegKeyExists(HKLM, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages\Package_for_KB3033929~31bf3856ad364e35~amd64~~6.1.1.3') or
    RegKeyExists(HKLM, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages\Package_for_KB3033929~31bf3856ad364e35~amd64~~6.1.1.4') or
    RegKeyExists(HKLM, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages\Package_for_KB3033929~31bf3856ad364e35~amd64~~6.1.1.5') or
    RegKeyExists(HKLM, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages\Package_for_KB3033929~31bf3856ad364e35~amd64~~6.1.2.0');
end;

function EnsurePrereq(const FileName, Url, DisplayName: string; var LocalPath: string): Boolean;
var
  SetupDir, DestTmp, DestLocal: string;
  rc: Integer;
begin
  Result := False;
  LocalPath := '';

  // 1) Offline-friendly: if user put file next to Setup EXE
  SetupDir := ExtractFileDir(ExpandConstant('{srcexe}'));
  DestLocal := SetupDir + '\' + FileName;
  if FileExists(DestLocal) then
  begin
    LocalPath := DestLocal;
    Result := True;
    Exit;
  end;

  // 2) Download to {tmp}
  DestTmp := ExpandConstant('{tmp}\') + FileName;
  if FileExists(DestTmp) then DeleteFile(DestTmp);

  WizardForm.StatusLabel.Caption := 'Lade herunter: ' + DisplayName;
  rc := URLDownloadToFileW(0, Url, DestTmp, 0, 0);

  if (rc = 0) and FileExists(DestTmp) then
  begin
    LocalPath := DestTmp;
    Result := True;
  end;
end;

procedure FailPrereq(const FileName, DisplayName: string);
begin
  MsgBox(
    DisplayName + ' wird benötigt, konnte aber nicht gefunden/heruntergeladen werden.' + #13#10 + #13#10 +
    'Lösung:' + #13#10 +
    '- Internetverbindung/Proxy prüfen (Win7 benötigt TLS 1.2 Updates)' + #13#10 +
    '- oder Datei neben das Setup legen:' + #13#10 +
    '  ' + FileName,
    mbError, MB_OK
  );
  Abort;
end;

procedure InstallKB3033929IfNeeded();
var
  Path: string;
  ResultCode: Integer;
begin
  if not IsWin7Or2008R2 then Exit;
  if HasKB3033929 then Exit;

  if EnsurePrereq(KB3033929FileName, KB3033929Url, 'KB3033929 (SHA-256 Support)', Path) then
  begin
    WizardForm.StatusLabel.Caption := 'Installiere KB3033929 (SHA-256 Support)...';
    if not Exec('wusa.exe', '"' + Path + '" /quiet /norestart', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      FailPrereq(KB3033929FileName, 'KB3033929 Installation');
    NeedRestart := True;
  end
  else
    FailPrereq(KB3033929FileName, 'KB3033929 (SHA-256 Support)');
end;

procedure InstallWMF51IfNeeded();
var
  Path: string;
  ResultCode: Integer;
begin
  if not NeedsWMF51 then Exit;

  if EnsurePrereq(WMF51FileName, WMF51Url, 'WMF 5.1 / PowerShell 5.1', Path) then
  begin
    WizardForm.StatusLabel.Caption := 'Installiere WMF 5.1 / PowerShell 5.1...';
    if not Exec('wusa.exe', '"' + Path + '" /quiet /norestart', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      FailPrereq(WMF51FileName, 'WMF 5.1 Installation');
    NeedRestart := True;
  end
  else
    FailPrereq(WMF51FileName, 'WMF 5.1 / PowerShell 5.1');
end;

procedure InstallDotNet48IfNeeded();
var
  Path: string;
  ResultCode: Integer;
begin
  if not NeedsDotNet48 then Exit;

  if EnsurePrereq(DotNet48FileName, DotNet48Url, '.NET Framework 4.8', Path) then
  begin
    WizardForm.StatusLabel.Caption := 'Installiere .NET Framework 4.8...';
    if not Exec(Path, '/passive /norestart', '', SW_SHOW, ewWaitUntilTerminated, ResultCode) then
      FailPrereq(DotNet48FileName, '.NET 4.8 Installation');
    NeedRestart := True;
  end
  else
    FailPrereq(DotNet48FileName, '.NET Framework 4.8');
end;

procedure InitializeWizard();
begin
  // Restart recommended if any prerequisite is needed
  NeedRestart := NeedsDotNet48 or NeedsWMF51 or (IsWin7Or2008R2 and (not HasKB3033929));
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssInstall then
  begin
    // Win7 order: SHA-256 support first
    InstallKB3033929IfNeeded();

   // then WMF (if needed)
    InstallWMF51IfNeeded();

   // then .NET (if needed)
    InstallDotNet48IfNeeded();
  end;

  if CurStep = ssPostInstall then
  begin
    if NeedRestart then
    begin
      if MsgBox(
           'Ein Neustart wird empfohlen, um die Installation (Framework/PowerShell) vollständig abzuschließen.' + #13#10 + #13#10 +
           'Möchten Sie den Computer jetzt neu starten?',
           mbConfirmation, MB_YESNO
         ) = IDYES then
      begin
        Exec('shutdown.exe', '/r /t 15 /c "GhettoGUI Setup: Neustart"', '', SW_HIDE, ewNoWait, ResultCode);
      end;
    end;
  end;
end;
