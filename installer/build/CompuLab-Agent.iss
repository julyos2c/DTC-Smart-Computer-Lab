; CompuLab Agent setup (Inno Setup 6). Built by installer\build\build-installers.ps1,
; which packages the agent as CompuLabAgent.exe (PyInstaller, so lab PCs need no
; Python) and passes /DPayload=... /DAppVersion=... /DFileVersion=... /DOutputDir=...
;
; The setup asks for the PC's Agent config file (CompuLab > PC status > Agent
; config); an agent_config.local.json next to the setup .exe is picked up
; automatically. It then runs installer\agent\install-agent.ps1 from the
; payload, which installs to C:\Program Files\CompuLab Agent, registers the
; start-at-sign-in task, opens the firewall for the server only and runs the
; agent's self-test. The setup itself contains no secret and can be shared.
;
; Silent install on many PCs (as Administrator):
;   CompuLab-Agent-Setup.exe /VERYSILENT /CONFIG="\\server\share\pc-01.json"
; Silent update keeping the PC's settings:
;   CompuLab-Agent-Setup.exe /VERYSILENT

#ifndef Payload
  #error Payload is not defined: build with installer\build\build-installers.ps1
#endif

[Setup]
#ifdef TestBuild
; Test build (installer\tests): per-user, no admin rights, separate AppId.
AppId={{3A9E5C1F-7B2D-4E8A-B6C4-91D0F2E77E57}
PrivilegesRequired=lowest
#else
AppId={{3A9E5C1F-7B2D-4E8A-B6C4-91D0F2E7A355}
PrivilegesRequired=admin
#endif
AppName=CompuLab Agent
AppVersion={#AppVersion}
AppVerName=CompuLab Agent {#AppVersion}
AppPublisher=Danao Technological College
VersionInfoVersion={#FileVersion}
VersionInfoDescription=CompuLab lab PC agent setup
DefaultDirName={autopf}\CompuLab Agent
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=CompuLab-Agent-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
UninstallFilesDir={app}\uninstall
UninstallDisplayName=CompuLab Agent
CloseApplications=no
RestartApplications=no
; See CompuLab-Server.iss: the installer script must not inherit Windows'
; RedirectionGuard; the install folder is checked in PrepareToInstall instead.
RedirectionGuard=no

[Files]
Source: "{#Payload}\*"; DestDir: "{tmp}\payload"; Flags: ignoreversion recursesubdirs createallsubdirs deleteafterinstall

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\tools\uninstall-agent.ps1"" -InstallDir ""{app}"" -KeepFiles"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveCompuLabAgent"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Messages]
UninstalledAll=The CompuLab agent was removed from this PC.%n%nEvents still waiting to be sent were kept in C:\ProgramData\CompuLab Agent (delete that folder to remove them).

[Code]
var
  ConfigPage: TInputFileWizardPage;
  ManualPage: TInputQueryWizardPage;

function GetFileAttributes(lpFileName: String): Cardinal;
  external 'GetFileAttributesW@kernel32.dll stdcall';

function IsReparsePoint(Path: String): Boolean;
var
  Attr: Cardinal;
begin
  Attr := GetFileAttributes(RemoveBackslashUnlessRoot(Path));
  Result := (Attr <> $FFFFFFFF) and ((Attr and $400) <> 0);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if IsReparsePoint(WizardDirValue()) or IsReparsePoint(ExtractFileDir(WizardDirValue())) then
    Result := 'The agent folder ' + WizardDirValue() + ' (or its parent) is a junction or symbolic link; remove it and run this setup again.';
end;

function HasInstalledConfig(): Boolean;
begin
  // WizardDirValue: the install folder is known before the (hidden) folder page.
  Result := FileExists(AddBackslash(WizardDirValue()) + 'agent_config.local.json');
end;

function JsonEscape(S: String): String;
begin
  StringChangeEx(S, '\', '\\', True);
  StringChangeEx(S, '"', '\"', True);
  Result := S;
end;

procedure InitializeWizard;
var
  Default: String;
begin
  ConfigPage := CreateInputFilePage(wpWelcome, 'Agent settings',
    'Choose this PC''s Agent config file',
    'In CompuLab (as Admin): PC status > this PC''s row > Agent config downloads agent_config.local.json. ' +
    'It contains the server address and the agent secret: keep it private and delete it from the USB stick afterwards.' + #13#10#13#10 +
    'Leave this empty to keep the settings already on this PC, or to type the server address and secret on the next page.');
  ConfigPage.Add('Agent config file:', 'Agent config (*.json)|*.json|All files|*.*', '.json');
  Default := ExpandConstant('{param:CONFIG|}');
  if (Default = '') and FileExists(ExpandConstant('{src}\agent_config.local.json')) then
    Default := ExpandConstant('{src}\agent_config.local.json');
  ConfigPage.Values[0] := Default;

  ManualPage := CreateInputQueryPage(ConfigPage.ID, 'Server address and secret',
    'Enter the CompuLab server details',
    'The campus address is shown on CompuLab''s System status page, for example http://192.168.1.10:8000. ' +
    'The agent secret is PC_AGENT_SHARED_SECRET in the server''s .env file.');
  ManualPage.Add('CompuLab server address:', False);
  ManualPage.Add('Agent secret:', True);
  ManualPage.Values[0] := ExpandConstant('{param:SERVER|}');
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := (PageID = ManualPage.ID) and ((Trim(ConfigPage.Values[0]) <> '') or HasInstalledConfig());
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = ConfigPage.ID) and (Trim(ConfigPage.Values[0]) <> '') and not FileExists(ConfigPage.Values[0]) then
  begin
    MsgBox('That file does not exist.', mbError, MB_OK);
    Result := False;
  end;
  if CurPageID = ManualPage.ID then
  begin
    if (Pos('http://', Lowercase(ManualPage.Values[0])) <> 1) and (Pos('https://', Lowercase(ManualPage.Values[0])) <> 1) then
    begin
      MsgBox('The server address must start with http:// (for example http://192.168.1.10:8000).', mbError, MB_OK);
      Result := False;
    end
    else if Length(ManualPage.Values[1]) < 16 then
    begin
      MsgBox('Enter the agent secret (PC_AGENT_SHARED_SECRET from the server''s .env).', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Params, ConfigFile, Payload: String;
  Code, Show: Integer;
begin
  if CurStep <> ssPostInstall then Exit;
  Payload := ExpandConstant('{tmp}\payload');
  ConfigFile := Trim(ConfigPage.Values[0]);
  if (ConfigFile = '') and (Trim(ManualPage.Values[0]) <> '') and not HasInstalledConfig() then
  begin
    // Typed details: a temporary config file (deleted with {tmp} at the end).
    ConfigFile := ExpandConstant('{tmp}\agent_config.local.json');
    SaveStringToFile(ConfigFile, '{"secret": "' + JsonEscape(ManualPage.Values[1]) + '", "server_url": "' +
      JsonEscape(Trim(ManualPage.Values[0])) + '", "port": 5555}', False);
  end;
  Params := '-NoProfile -ExecutionPolicy Bypass -File "' + Payload + '\installer\agent\install-agent.ps1" -NonInteractive -SourceDir "' +
    Payload + '\agent-bundle"';
  if ConfigFile <> '' then Params := Params + ' -ConfigFile "' + ConfigFile + '"';
#ifdef TestBuild
  Params := Params + ' ' + ExpandConstant('{param:PSARGS|}');
#endif
  if WizardSilent() then Show := SW_HIDE
  else
  begin
    Params := Params + ' -PauseAtEnd';
    Show := SW_SHOW;
  end;
  WizardForm.StatusLabel.Caption := 'Installing the CompuLab agent (a console window shows the progress)...';
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Params, Payload, Show, ewWaitUntilTerminated, Code) or (Code <> 0) then
  begin
    Log('install-agent.ps1 failed with exit code ' + IntToStr(Code));
    SuppressibleMsgBox('The CompuLab agent was not installed completely (exit code ' + IntToStr(Code) + ').' + #13#10#13#10 +
      'The reason is shown in the console window and in C:\ProgramData\CompuLab Agent\install-*.log.' + #13#10 +
      'Fix it (usually: the Agent config file) and run this setup again.', mbError, MB_OK, IDOK);
  end;
end;
