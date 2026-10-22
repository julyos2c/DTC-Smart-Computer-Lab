; CompuLab Server setup (Inno Setup 6). Built by installer\build\build-installers.ps1,
; which stages the payload (application files, WinSW, offline Python packages)
; and passes /DPayload=... /DAppVersion=... /DFileVersion=... /DOutputDir=...
;
; The setup copies the program to C:\CompuLab (or the chosen folder) and runs
; installer\server\install-server.ps1, which does the real work (checks, venv,
; .env, database, migrations, services, firewall, backups) and can be re-run
; at any time. Running a newer setup over an installed server updates it.
;
; Silent install (Python and MariaDB already installed; the MariaDB root
; password in the environment variable COMPULAB_DB_ROOT_PASSWORD):
;   CompuLab-Server-Setup.exe /VERYSILENT /SERVERADDRESS=192.168.1.10 /PORT=8000

#ifndef Payload
  #error Payload is not defined: build with installer\build\build-installers.ps1
#endif

[Setup]
#ifdef TestBuild
; Test build (installer\tests): per-user, no admin rights, separate AppId.
AppId={{6F0B2D52-3C61-4E1B-9A57-2B7C2B1D7E57}
PrivilegesRequired=lowest
#else
AppId={{6F0B2D52-3C61-4E1B-9A57-2B7C2B1D4A10}
PrivilegesRequired=admin
#endif
AppName=CompuLab Server
AppVersion={#AppVersion}
AppVerName=CompuLab Server {#AppVersion}
AppPublisher=Danao Technological College
VersionInfoVersion={#FileVersion}
VersionInfoDescription=CompuLab Server setup
DefaultDirName=C:\CompuLab
UsePreviousAppDir=yes
DirExistsWarning=no
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=CompuLab-Server-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
UninstallDisplayName=CompuLab Server
CloseApplications=no
RestartApplications=no
; Inno Setup 6.7 enables Windows' RedirectionGuard by default, and the
; installer script inherits it: Python, pip and the MySQL client then fail
; ("WinError 448 ... untrusted mount point") on PCs whose PATH contains a
; junction created by a normal user. The install folder itself is checked
; below instead (PrepareToInstall refuses a junction / symbolic link).
RedirectionGuard=no

[InstallDelete]
; Old program code only (so files removed in a newer version don't linger).
; Never listed here: .env, media, backups, logs, venv, service, staticfiles.
Type: filesandordirs; Name: "{app}\accounts"
Type: filesandordirs; Name: "{app}\cloud_sync"
Type: filesandordirs; Name: "{app}\compulab"
Type: filesandordirs; Name: "{app}\issues"
Type: filesandordirs; Name: "{app}\labs"
Type: filesandordirs; Name: "{app}\notifications"
Type: filesandordirs; Name: "{app}\scheduling"
Type: filesandordirs; Name: "{app}\system"
Type: filesandordirs; Name: "{app}\static"
Type: filesandordirs; Name: "{app}\lab_pc_agent"
Type: filesandordirs; Name: "{app}\installer"
Type: filesandordirs; Name: "{app}\docs"

[Files]
Source: "{#Payload}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\CompuLab\CompuLab Server Status"; Filename: "{app}\installer\server\Server Status.cmd"; WorkingDir: "{app}\installer\server"
Name: "{autoprograms}\CompuLab\Back Up CompuLab Now"; Filename: "{app}\installer\server\Backup Now.cmd"; WorkingDir: "{app}\installer\server"
Name: "{autoprograms}\CompuLab\Repair CompuLab Server"; Filename: "{app}\Install CompuLab Server.cmd"; WorkingDir: "{app}"
Name: "{autoprograms}\CompuLab\School Deployment Guide"; Filename: "{app}\docs\SCHOOL_DEPLOYMENT_GUIDE.md"

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\installer\server\uninstall-server.ps1"" -Quiet"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveCompuLabServices"

[Messages]
FinishedLabelNoIcons=The CompuLab Server files are installed and the setup window showed the result.%n%nIf it reported a problem, fix it and run this setup (or "Repair CompuLab Server" in the Start menu) again: it continues safely.
UninstalledAll=The CompuLab services, firewall rules and backup task were removed.%n%nThe database, settings (.env), uploads, backups and logs were KEPT in the program folder and in MariaDB.

[Code]
var
  AddressPage: TInputQueryWizardPage;
  WasInstalled: Boolean;

function GetFileAttributes(lpFileName: String): Cardinal;
  external 'GetFileAttributesW@kernel32.dll stdcall';

function IsReparsePoint(Path: String): Boolean;
var
  Attr: Cardinal;
begin
  Attr := GetFileAttributes(RemoveBackslashUnlessRoot(Path));
  // INVALID_FILE_ATTRIBUTES = $FFFFFFFF (does not exist); REPARSE_POINT = $400
  Result := (Attr <> $FFFFFFFF) and ((Attr and $400) <> 0);
end;

function IsInstalled(): Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\.env'));
end;

procedure InitializeWizard;
begin
  AddressPage := CreateInputQueryPage(wpSelectDir, 'Campus address',
    'How lab PCs and staff will reach this server',
    'Enter this server''s fixed campus IP address (reserve it in the router first), for example 192.168.1.10. ' +
    'Leave it empty to pick from this computer''s addresses during the installation. The port is normally 8000.');
  AddressPage.Add('Campus IP address or computer name:', False);
  AddressPage.Add('Port:', False);
  AddressPage.Values[0] := ExpandConstant('{param:SERVERADDRESS|}');
  AddressPage.Values[1] := ExpandConstant('{param:PORT|8000}');
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  // An installed server keeps its address (change it with set-server-address.ps1).
  Result := (PageID = AddressPage.ID) and IsInstalled();
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  P: Integer;
begin
  Result := True;
  if CurPageID = AddressPage.ID then
  begin
    P := StrToIntDef(Trim(AddressPage.Values[1]), 0);
    if (P < 1) or (P > 65535) then
    begin
      MsgBox('The port must be a number from 1 to 65535 (normally 8000).', mbError, MB_OK);
      Result := False;
    end
    else if (Pos('://', AddressPage.Values[0]) > 0) or (Pos(':', AddressPage.Values[0]) > 0) or (Pos(' ', Trim(AddressPage.Values[0])) > 0) then
    begin
      MsgBox('Enter only the address, for example 192.168.1.10 (no http:// and no port).', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  if IsReparsePoint(ExpandConstant('{app}')) or IsReparsePoint(ExtractFileDir(ExpandConstant('{app}'))) then
  begin
    Result := 'The install folder ' + ExpandConstant('{app}') + ' (or its parent) is a junction or symbolic link. ' +
      'Choose a normal folder, for example C:\CompuLab.';
    Exit;
  end;
  // Stop a running CompuLab before its files are replaced (update). net stop
  // waits until the service has stopped (an error when it is not installed
  // is fine).
  WasInstalled := IsInstalled();
  Exec(ExpandConstant('{sys}\net.exe'), 'stop CompuLabWorker /y', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Exec(ExpandConstant('{sys}\net.exe'), 'stop CompuLabWeb /y', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Params: String;
  Code: Integer;
  Show: Integer;
begin
  if CurStep <> ssPostInstall then Exit;
  Params := '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\installer\server\install-server.ps1') + '"';
  if (not WasInstalled) and (Trim(AddressPage.Values[0]) <> '') then
    Params := Params + ' -ServerAddress "' + Trim(AddressPage.Values[0]) + '"';
  if not WasInstalled then
    Params := Params + ' -Port ' + IntToStr(StrToIntDef(Trim(AddressPage.Values[1]), 8000));
#ifdef TestBuild
  Params := Params + ' ' + ExpandConstant('{param:PSARGS|}');
#endif
  if WizardSilent() then
  begin
    Params := Params + ' -NonInteractive';
    Show := SW_HIDE;
  end
  else
  begin
    Params := Params + ' -PauseAtEnd';
    Show := SW_SHOW;
  end;
  WizardForm.StatusLabel.Caption := 'Setting up CompuLab (a console window shows the progress)...';
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Params, ExpandConstant('{app}'), Show, ewWaitUntilTerminated, Code) or (Code <> 0) then
  begin
    Log('install-server.ps1 failed with exit code ' + IntToStr(Code));
    SuppressibleMsgBox('CompuLab setup did not finish (exit code ' + IntToStr(Code) + ').' + #13#10#13#10 +
      'The reason is shown in the console window and in ' + ExpandConstant('{app}\logs') + ' (install-*.log).' + #13#10 +
      'Fix it and run this setup again; it continues safely.', mbError, MB_OK, IDOK);
  end;
end;
