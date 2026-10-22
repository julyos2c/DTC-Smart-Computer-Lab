Put the WinSW service wrapper here before running install-server.ps1:

  1. Download WinSW-x64.exe from https://github.com/winsw/winsw/releases
     (version 2.12 or newer, file "WinSW-x64.exe").
  2. Save it in this folder (installer\server\bin\WinSW-x64.exe).

install-server.ps1 copies it to service\CompuLabWeb.exe and
service\CompuLabWorker.exe and writes their settings (.xml) next to them.
The .exe is not stored in the repository (binary, third-party).
