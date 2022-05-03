$TASKCLUSTER_VERSION = "44.13.4"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Get-ChildItem Env: | Out-File "C:\install_env.txt"
$client = New-Object system.net.WebClient
$shell = new-object -com shell.application
function Expand-ZIPFile($file, $destination, $url)
{
    $client.DownloadFile($url, $file)
    $zip = $shell.NameSpace($file)
    foreach($item in $zip.items())
    {
        $shell.Namespace($destination).copyhere($item)
    }
}
Set-ExecutionPolicy Unrestricted -Force -Scope Process
Invoke-Expression ($client.DownloadString('https://chocolatey.org/install.ps1'))
choco install -y windows-sdk-8.1
$client.DownloadFile("http://download.microsoft.com/download/A/E/7/AE743F1F-632B-4809-87A9-AA1BB3458E31/DXSDK_Jun10.exe", "C:\DXSDK_Jun10.exe")
Install-WindowsFeature NET-Framework-Core
Start-Process C:\DXSDK_Jun10.exe -ArgumentList "/U" -Wait -NoNewWindow -PassThru -RedirectStandardOutput C:\directx_sdk_install.log -RedirectStandardError C:\directx_sdk_install.err
$client.DownloadFile("http://download.microsoft.com/download/2/E/6/2E61CFA4-993B-4DD4-91DA-3737CD5CD6E3/vcredist_x86.exe", "C:\vcredist_x86-vs2013.exe")
Start-Process "C:\vcredist_x86-vs2013.exe" -ArgumentList "/install /passive /norestart /log C:\vcredist_x86-vs2013-install.log" -Wait -PassThru
Start-Process "C:\vcredist_x64-vs2013.exe" -ArgumentList "/install /passive /norestart /log C:\vcredist_x64-vs2013-install.log" -Wait -PassThru
Start-Process "C:\vcredist_x86-vs2015.exe" -ArgumentList "/install /passive /norestart /log C:\vcredist_x86-vs2015-install.log" -Wait -PassThru
Start-Process "C:\vcredist_x64-vs2015.exe" -ArgumentList "/install /passive /norestart /log C:\vcredist_x64-vs2015-install.log" -Wait -PassThru
Start-Process "C:\vcredist_x86-vs2010.exe" -ArgumentList "/install /passive /norestart /log C:\vcredist_x86-vs2010-install.log" -Wait -PassThru
Start-Process "C:\vcredist_x64-vs2010.exe" -ArgumentList "/install /passive /norestart /log C:\vcredist_x64-vs2010-install.log" -Wait -PassThru
$client.DownloadFile("https://ftp.mozilla.org/pub/mozilla.org/mozilla/libraries/win32/MozillaBuildSetup-Latest.exe", "C:\MozillaBuildSetup.exe")
Start-Process "C:\MozillaBuildSetup.exe" -ArgumentList "/S" -Wait -NoNewWindow -PassThru -RedirectStandardOutput "C:\MozillaBuild_install.log" -RedirectStandardError "C:\MozillaBuild_install.err"
md "C:\builds"
$acl = Get-Acl -Path "C:\builds"
$ace = New-Object System.Security.AccessControl.FileSystemAccessRule("Everyone","Full","ContainerInherit,ObjectInherit","None","Allow")
$acl.AddAccessRule($ace)
Set-Acl "C:\builds" $acl
$client.DownloadFile("https://raw.githubusercontent.com/mozilla/release-services/master/src/tooltool/client/tooltool.py", "C:\builds\tooltool.py")
Expand-ZIPFile -File "C:\nssm-2.24.zip" -Destination "C:\" -Url "http://www.nssm.cc/release/nssm-2.24.zip"
md C:\generic-worker
$client.DownloadFile("https://github.com/taskcluster/taskcluster/releases/download/v${TASKCLUSTER_VERSION}/generic-worker-multiuser-windows-amd64", "C:\generic-worker\generic-worker.exe")
Set-Content -Path c:\generic-worker\install.bat @"
set nssm=C:\nssm-2.24\win64\nssm.exe
%nssm% install "Generic Worker" c:\generic-worker\generic-worker.exe
%nssm% set "Generic Worker" AppDirectory c:\generic-worker
%nssm% set "Generic Worker" AppParameters run --config c:\generic-worker\generic-worker-config.yml --worker-runner-protocol-pipe \\.\pipe\generic-worker
%nssm% set "Generic Worker" DisplayName "Generic Worker"
%nssm% set "Generic Worker" Description "A taskcluster worker that runs on all mainstream platforms"
%nssm% set "Generic Worker" Start SERVICE_DEMAND_START
%nssm% set "Generic Worker" Type SERVICE_WIN32_OWN_PROCESS
%nssm% set "Generic Worker" AppNoConsole 1
%nssm% set "Generic Worker" AppAffinity All
%nssm% set "Generic Worker" AppStopMethodSkip 0
%nssm% set "Generic Worker" AppExit Default Exit
%nssm% set "Generic Worker" AppRestartDelay 0
%nssm% set "Generic Worker" AppStdout c:\generic-worker\generic-worker-service.log
%nssm% set "Generic Worker" AppStderr c:\generic-worker\generic-worker-service.log
%nssm% set "Generic Worker" AppRotateFiles 0
"@
Start-Process C:\generic-worker\install.bat -Wait -NoNewWindow -RedirectStandardOutput C:\generic-worker\install.log -RedirectStandardError C:\generic-worker\install.err
md C:\worker-runner
$client.DownloadFile("https://github.com/taskcluster/taskcluster/releases/download/v${TASKCLUSTER_VERSION}/start-worker-windows-amd64", "C:\worker-runner\start-worker.exe")
Set-Content -Path c:\worker-runner\install.bat @"
set nssm=C:\nssm-2.24\win64\nssm.exe
%nssm% install worker-runner c:\worker-runner\start-worker.exe
%nssm% set worker-runner AppDirectory c:\worker-runner
%nssm% set worker-runner AppParameters c:\worker-runner\runner.yml
%nssm% set worker-runner DisplayName "Worker Runner"
%nssm% set worker-runner Description "Interface between workers and Taskcluster services"
%nssm% set worker-runner Start SERVICE_AUTO_START
%nssm% set worker-runner Type SERVICE_WIN32_OWN_PROCESS
%nssm% set worker-runner AppNoConsole 1
%nssm% set worker-runner AppAffinity All
%nssm% set worker-runner AppStopMethodSkip 0
%nssm% set worker-runner AppExit Default Exit
%nssm% set worker-runner AppRestartDelay 0
%nssm% set worker-runner AppStdout c:\worker-runner\worker-runner-service.log
%nssm% set worker-runner AppStderr c:\worker-runner\worker-runner-service.log
%nssm% set worker-runner AppRotateFiles 1
%nssm% set worker-runner AppRotateOnline 1
%nssm% set worker-runner AppRotateSeconds 3600
%nssm% set worker-runner AppRotateBytes 0
"@
Start-Process C:\worker-runner\install.bat -Wait -NoNewWindow -RedirectStandardOutput C:\worker-runner\install.log -RedirectStandardError C:\worker-runner\install.err
Set-Content -Path c:\worker-runner\runner.yml @"
provider:
    providerType: %MY_CLOUD%
worker:
  implementation: generic-worker
  service: "Generic Worker"
  configPath: c:\generic-worker\generic-worker-config.yml
  protocolPipe: \\.\pipe\generic-worker
cacheOverRestarts: c:\generic-worker\start-worker-cache.json
"@
$client.DownloadFile("https://github.com/taskcluster/taskcluster/releases/download/v${TASKCLUSTER_VERSION}/livelog-windows-amd64", "C:\generic-worker\livelog.exe")
$client.DownloadFile("https://github.com/taskcluster/taskcluster/releases/download/v${TASKCLUSTER_VERSION}/taskcluster-proxy-windows-amd64", "C:\generic-worker\taskcluster-proxy.exe")
$HostsFile_Base64 = "IyBDb3B5cmlnaHQgKGMpIDE5OTMtMjAwOSBNaWNyb3NvZnQgQ29ycC4NCiMNCiMgVGhpcyBpcyBhIHNhbXBsZSBIT1NUUyBmaWxlIHVzZWQgYnkgTWljcm9zb2Z0IFRDUC9JUCBmb3IgV2luZG93cy4NCiMNCiMgVGhpcyBmaWxlIGNvbnRhaW5zIHRoZSBtYXBwaW5ncyBvZiBJUCBhZGRyZXNzZXMgdG8gaG9zdCBuYW1lcy4gRWFjaA0KIyBlbnRyeSBzaG91bGQgYmUga2VwdCBvbiBhbiBpbmRpdmlkdWFsIGxpbmUuIFRoZSBJUCBhZGRyZXNzIHNob3VsZA0KIyBiZSBwbGFjZWQgaW4gdGhlIGZpcnN0IGNvbHVtbiBmb2xsb3dlZCBieSB0aGUgY29ycmVzcG9uZGluZyBob3N0IG5hbWUuDQojIFRoZSBJUCBhZGRyZXNzIGFuZCB0aGUgaG9zdCBuYW1lIHNob3VsZCBiZSBzZXBhcmF0ZWQgYnkgYXQgbGVhc3Qgb25lDQojIHNwYWNlLg0KIw0KIyBBZGRpdGlvbmFsbHksIGNvbW1lbnRzIChzdWNoIGFzIHRoZXNlKSBtYXkgYmUgaW5zZXJ0ZWQgb24gaW5kaXZpZHVhbA0KIyBsaW5lcyBvciBmb2xsb3dpbmcgdGhlIG1hY2hpbmUgbmFtZSBkZW5vdGVkIGJ5IGEgJyMnIHN5bWJvbC4NCiMNCiMgRm9yIGV4YW1wbGU6DQojDQojICAgICAgMTAyLjU0Ljk0Ljk3ICAgICByaGluby5hY21lLmNvbSAgICAgICAgICAjIHNvdXJjZSBzZXJ2ZXINCiMgICAgICAgMzguMjUuNjMuMTAgICAgIHguYWNtZS5jb20gICAgICAgICAgICAgICMgeCBjbGllbnQgaG9zdA0KDQojIGxvY2FsaG9zdCBuYW1lIHJlc29sdXRpb24gaXMgaGFuZGxlZCB3aXRoaW4gRE5TIGl0c2VsZi4NCiMJMTI3LjAuMC4xICAgICAgIGxvY2FsaG9zdA0KIwk6OjEgICAgICAgICAgICAgbG9jYWxob3N0DQoNCiMgVXNlZnVsIGZvciBnZW5lcmljLXdvcmtlciB0YXNrY2x1c3Rlci1wcm94eSBpbnRlZ3JhdGlvbg0KIyBTZWUgaHR0cHM6Ly9idWd6aWxsYS5tb3ppbGxhLm9yZy9zaG93X2J1Zy5jZ2k/aWQ9MTQ0OTk4MSNjNg0KMTI3LjAuMC4xICAgICAgICB0YXNrY2x1c3RlciAgICANCg=="
$HostsFile_Content = [System.Convert]::FromBase64String($HostsFile_Base64)
Set-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value $HostsFile_Content -Encoding Byte
Start-Process C:\generic-worker\generic-worker.exe -ArgumentList "install service --configure-for-%MY_CLOUD% --nssm C:\nssm-2.24\win64\nssm.exe --config C:\generic-worker\generic-worker.config" -Wait -NoNewWindow -PassThru -RedirectStandardOutput C:\generic-worker\install.log -RedirectStandardError C:\generic-worker\install.err
$client.DownloadFile("https://download.microsoft.com/download/8/e/c/8ec3a7d8-05b4-440a-a71e-ca3ee25fe057/rktools.exe", "C:\rktools.exe")
$client.DownloadFile("http://artfiles.org/vim.org/pc/gvim80-069.exe", "C:\gvim80-069.exe")
$client.DownloadFile("https://download.microsoft.com/download/2/6/A/26AAA1DE-D060-4246-93B5-7D7C877E4F8F/BinScopeSetup.msi", "C:\BinScopeSetup.msi")
Start-Process "msiexec" -ArgumentList "/i C:\BinScopeSetup.msi /quiet" -Wait -NoNewWindow -PassThru -RedirectStandardOutput "C:\binscope-install.log" -RedirectStandardError "C:\binscope-install.err"
New-NetFirewallRule -DisplayName "Allow livelog PUT requests" -Direction Inbound -LocalPort 60022 -Protocol TCP -Action Allow
New-NetFirewallRule -DisplayName "Allow livelog GET requests" -Direction Inbound -LocalPort 60023 -Protocol TCP -Action Allow
md "C:\gopath"
Expand-ZIPFile -File "C:\go1.18.1.windows-amd64.zip" -Destination "C:\" -Url "https://storage.googleapis.com/golang/go1.18.1.windows-amd64.zip"
$client.DownloadFile("https://github.com/git-for-windows/git/releases/download/v2.16.2.windows.1/Git-2.16.2-64-bit.exe", "C:\Git-2.16.2-64-bit.exe")
Start-Process "C:\Git-2.16.2-64-bit.exe" -ArgumentList "/VERYSILENT /LOG=C:\git_install.log /NORESTART /SUPPRESSMSGBOXES" -Wait -NoNewWindow
$client.DownloadFile("http://aka.ms/downloadazcopy", "C:\AZCopy.msi")
Start-Process "msiexec" -ArgumentList "/i C:\AZCopy.msi /quiet" -Wait -NoNewWindow -PassThru -RedirectStandardOutput "C:\AZCopy-install.log" -RedirectStandardError "C:\AZCopy-install.err"
$client.DownloadFile("https://nodejs.org/dist/v6.6.0/node-v6.6.0-x64.msi", "C:\NodeSetup.msi")
Start-Process "msiexec" -ArgumentList "/i C:\NodeSetup.msi /quiet" -Wait -NoNewWindow -PassThru -RedirectStandardOutput "C:\node-install.log" -RedirectStandardError "C:\node-install.err"
[Environment]::SetEnvironmentVariable("GOROOT", "C:\go", "Machine")
[Environment]::SetEnvironmentVariable("PATH", $Env:Path + ";C:\Program Files\Vim\vim80;C:\go\bin;C:\gopath\bin;C:\mozilla-build\python;C:\mozilla-build\python\Scripts;C:\Program Files\Git\cmd;C:\Program Files\nodejs", "Machine")
[Environment]::SetEnvironmentVariable("GOPATH", "C:\gopath", "Machine")
Start-Process "C:\mozilla-build\python\python.exe" -ArgumentList "-m pip install --upgrade pip==8.1.1 setuptools==20.7.0 virtualenv==15.0.3 wheel==0.29.0 pypiwin32==219 requests==2.9.1 psutil==4.1.0" -Wait -NoNewWindow -PassThru -RedirectStandardOutput "C:\python_package_upgrades.log" -RedirectStandardError "C:\python_package_upgrades.err"
$env:GOROOT = "C:\go"
$env:GOPATH = "C:\gopath"
$env:PATH   = $env:PATH + ";C:\go\bin;C:\gopath\bin;C:\mozilla-build\python;C:\mozilla-build\python\Scripts;C:\Program Files\Git\cmd"
Start-Process "go" -ArgumentList "get -t github.com/taskcluster/generic-worker github.com/taskcluster/livelog" -Wait -NoNewWindow -PassThru -RedirectStandardOutput "C:\generic-worker\go-get_install.log" -RedirectStandardError "C:\generic-worker\go-get_install.err"
Start-Process C:\generic-worker\generic-worker.exe -ArgumentList "new-ed25519-keypair --file C:\generic-worker\generic-worker-ed25519-signing-key.key" -Wait -NoNewWindow -PassThru -RedirectStandardOutput C:\generic-worker\generate-signing-key.log -RedirectStandardError C:\generic-worker\generate-signing-key.err
$client.DownloadFile("https://www.cygwin.com/setup-x86_64.exe", "C:\cygwin-setup-x86_64.exe")
Start-Process "C:\cygwin-setup-x86_64.exe" -ArgumentList "--quiet-mode --wait --root C:\cygwin --site http://cygwin.mirror.constant.com --packages openssh,vim,curl,tar,wget,zip,unzip,diffutils,bzr" -Wait -NoNewWindow -PassThru -RedirectStandardOutput "C:\cygwin_install.log" -RedirectStandardError "C:\cygwin_install.err"
New-NetFirewallRule -DisplayName "Allow SSH inbound" -Direction Inbound -LocalPort 22 -Protocol TCP -Action Allow
$env:LOGONSERVER = "\\" + $env:COMPUTERNAME
Start-Process "C:\cygwin\bin\bash.exe" -ArgumentList "--login -c `"ssh-host-config -y -c 'ntsec mintty' -u 'cygwinsshd' -w 'qwe123QWE!@#'`"" -Wait -NoNewWindow -PassThru -RedirectStandardOutput "C:\cygrunsrv.log" -RedirectStandardError "C:\cygrunsrv.err"
Start-Process "net" -ArgumentList "start sshd" -Wait -NoNewWindow -PassThru -RedirectStandardOutput "C:\net_start_sshd.log" -RedirectStandardError "C:\net_start_sshd.err"
$client.DownloadFile("https://raw.githubusercontent.com/petemoore/myscrapbook/master/setup.sh", "C:\cygwin\home\Administrator\setup.sh")
Start-Process "C:\cygwin\bin\bash.exe" -ArgumentList "--login -c 'chmod a+x setup.sh; ./setup.sh'" -Wait -NoNewWindow -PassThru -RedirectStandardOutput "C:\Administrator_cygwin_setup.log" -RedirectStandardError "C:\Administrator_cygwin_setup.err"
md "C:\DependencyWalker"
Expand-ZIPFile -File "C:\depends22_x64.zip" -Destination "C:\DependencyWalker" -Url "http://dependencywalker.com/depends22_x64.zip"
md "C:\ProcessExplorer"
Expand-ZIPFile -File "C:\ProcessExplorer.zip" -Destination "C:\ProcessExplorer" -Url "https://download.sysinternals.com/files/ProcessExplorer.zip"
md "C:\ProcessMonitor"
Expand-ZIPFile -File "C:\ProcessMonitor.zip" -Destination "C:\ProcessMonitor" -Url "https://download.sysinternals.com/files/ProcessMonitor.zip"

# Download and install Unity and Visual Studio.
$client.DownloadFile("https://beta.unity3d.com/download/b073d123dd5d/Windows64EditorInstaller/UnitySetup64.exe", "UnitySetup64.exe")
$client.DownloadFile("https://beta.unity3d.com/download/b073d123dd5d/TargetSupportInstaller/UnitySetup-Windows-IL2CPP-Support-for-Editor-2019.3.0a12.exe", "UnitySetup-Windows-IL2CPP-Support-for-Editor-2019.3.0a12.exe")
# The Visual Studio download page  https://visualstudio.microsoft.com/thank-you-downloading-visual-studio/?sku=Community&rel=16 generates the download URL via Javascript.
$client.DownloadFile("https://download.visualstudio.microsoft.com/download/pr/f4e14058-49e0-457c-b3cf-f14e6f2f073e/7ba06b42c1d24060787dc2e7171e08ad964e47eccb30dabbfd791d56d086fca2/vs_Community.exe", "vs_Community.exe")
Start-Process -Wait -FilePath "UnitySetup64.exe" -ArgumentList "-UI=reduced /D=C:\Program Files\Unity"
Start-Process -Wait -FilePath "UnitySetup-Windows-IL2CPP-Support-for-Editor-2019.3.0a12.exe" -ArgumentList "/S /D=C:\Program Files\Unity"
Start-Process -Wait -FilePath "vs_community.exe" -ArgumentList "--productId `"Microsoft.VisualStudio.Product.Community`" --add `"Microsoft.VisualStudio.Workload.ManagedGame`" --add `"Microsoft.VisualStudio.Workload.NativeDesktop`" --add `"Microsoft.VisualStudio.Component.VC.Tools.x86.x64`" --add `"Microsoft.VisualStudio.Component.Windows10SDK.16299.Desktop`" --add `"Microsoft.VisualStudio.Component.Git`" --passive --norestart --wait"

shutdown -s
