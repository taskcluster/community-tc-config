$TASKCLUSTER_VERSION = "v58.0.1"

# use TLS 1.2 (see bug 1443595)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# capture env
Get-ChildItem Env: | Out-File "C:\install_env.txt"

# needed for making http requests
$client = New-Object system.net.WebClient
$shell = new-object -com shell.application

# utility function to download a zip file and extract it
function Expand-ZIPFile($file, $destination, $url)
{
    $client.DownloadFile($url, $file)
    $zip = $shell.NameSpace($file)
    foreach($item in $zip.items())
    {
        $shell.Namespace($destination).copyhere($item)
    }
}

# allow powershell scripts to run
Set-ExecutionPolicy Unrestricted -Force -Scope Process

# Issue 681: Uninstall Windows Defender as it can interfere with tasks,
# degrade their performance, and e.g. prevents Generic Worker unit test
# TestAbortAfterMaxRunTime from running as intended.
Uninstall-WindowsFeature -Name Windows-Defender

# Disable SysMain (Superfetch)
Set-Service "SysMain" -StartupType Disabled -Status Stopped

# Disable disk indexing
Set-Service "WSearch" -StartupType Disabled -Status Stopped

# install chocolatey package manager
Invoke-Expression ($client.DownloadString('https://chocolatey.org/install.ps1'))

# install nssm
Expand-ZIPFile -File "C:\nssm-2.24.zip" -Destination "C:\" -Url "http://www.nssm.cc/release/nssm-2.24.zip"

# download generic-worker
md C:\generic-worker
$client.DownloadFile("https://github.com/taskcluster/taskcluster/releases/download/${TASKCLUSTER_VERSION}/generic-worker-multiuser-windows-amd64", "C:\generic-worker\generic-worker.exe")

# install generic-worker, using the steps suggested in https://docs.taskcluster.net/docs/reference/workers/worker-runner/deployment#recommended-setup
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
Start-Process C:\generic-worker\install.bat -Wait -NoNewWindow

# download worker-runner
md C:\worker-runner
$client.DownloadFile("https://github.com/taskcluster/taskcluster/releases/download/${TASKCLUSTER_VERSION}/start-worker-windows-amd64", "C:\worker-runner\start-worker.exe")

# install worker-runner
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
Start-Process C:\worker-runner\install.bat -Wait -NoNewWindow

# configure worker-runner
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

# download livelog
$client.DownloadFile("https://github.com/taskcluster/taskcluster/releases/download/${TASKCLUSTER_VERSION}/livelog-windows-amd64", "C:\generic-worker\livelog.exe")

# download taskcluster-proxy
$client.DownloadFile("https://github.com/taskcluster/taskcluster/releases/download/${TASKCLUSTER_VERSION}/taskcluster-proxy-windows-amd64", "C:\generic-worker\taskcluster-proxy.exe")

# configure hosts file for taskcluster-proxy access via http://taskcluster
$HostsFile_Base64 = "IyBDb3B5cmlnaHQgKGMpIDE5OTMtMjAwOSBNaWNyb3NvZnQgQ29ycC4NCiMNCiMgVGhpcyBpcyBhIHNhbXBsZSBIT1NUUyBmaWxlIHVzZWQgYnkgTWljcm9zb2Z0IFRDUC9JUCBmb3IgV2luZG93cy4NCiMNCiMgVGhpcyBmaWxlIGNvbnRhaW5zIHRoZSBtYXBwaW5ncyBvZiBJUCBhZGRyZXNzZXMgdG8gaG9zdCBuYW1lcy4gRWFjaA0KIyBlbnRyeSBzaG91bGQgYmUga2VwdCBvbiBhbiBpbmRpdmlkdWFsIGxpbmUuIFRoZSBJUCBhZGRyZXNzIHNob3VsZA0KIyBiZSBwbGFjZWQgaW4gdGhlIGZpcnN0IGNvbHVtbiBmb2xsb3dlZCBieSB0aGUgY29ycmVzcG9uZGluZyBob3N0IG5hbWUuDQojIFRoZSBJUCBhZGRyZXNzIGFuZCB0aGUgaG9zdCBuYW1lIHNob3VsZCBiZSBzZXBhcmF0ZWQgYnkgYXQgbGVhc3Qgb25lDQojIHNwYWNlLg0KIw0KIyBBZGRpdGlvbmFsbHksIGNvbW1lbnRzIChzdWNoIGFzIHRoZXNlKSBtYXkgYmUgaW5zZXJ0ZWQgb24gaW5kaXZpZHVhbA0KIyBsaW5lcyBvciBmb2xsb3dpbmcgdGhlIG1hY2hpbmUgbmFtZSBkZW5vdGVkIGJ5IGEgJyMnIHN5bWJvbC4NCiMNCiMgRm9yIGV4YW1wbGU6DQojDQojICAgICAgMTAyLjU0Ljk0Ljk3ICAgICByaGluby5hY21lLmNvbSAgICAgICAgICAjIHNvdXJjZSBzZXJ2ZXINCiMgICAgICAgMzguMjUuNjMuMTAgICAgIHguYWNtZS5jb20gICAgICAgICAgICAgICMgeCBjbGllbnQgaG9zdA0KDQojIGxvY2FsaG9zdCBuYW1lIHJlc29sdXRpb24gaXMgaGFuZGxlZCB3aXRoaW4gRE5TIGl0c2VsZi4NCiMJMTI3LjAuMC4xICAgICAgIGxvY2FsaG9zdA0KIwk6OjEgICAgICAgICAgICAgbG9jYWxob3N0DQoNCiMgVXNlZnVsIGZvciBnZW5lcmljLXdvcmtlciB0YXNrY2x1c3Rlci1wcm94eSBpbnRlZ3JhdGlvbg0KIyBTZWUgaHR0cHM6Ly9idWd6aWxsYS5tb3ppbGxhLm9yZy9zaG93X2J1Zy5jZ2k/aWQ9MTQ0OTk4MSNjNg0KMTI3LjAuMC4xICAgICAgICB0YXNrY2x1c3RlciAgICANCg=="
$HostsFile_Content = [System.Convert]::FromBase64String($HostsFile_Base64)
Set-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value $HostsFile_Content -Encoding Byte

# download gvim
$client.DownloadFile("http://artfiles.org/vim.org/pc/gvim80-069.exe", "C:\gvim80-069.exe")

# open up firewall for livelog (both PUT and GET interfaces)
New-NetFirewallRule -DisplayName "Allow livelog PUT requests" -Direction Inbound -LocalPort 60022 -Protocol TCP -Action Allow
New-NetFirewallRule -DisplayName "Allow livelog GET requests" -Direction Inbound -LocalPort 60023 -Protocol TCP -Action Allow

# install go (not required, but useful)
md "C:\gopath"
Expand-ZIPFile -File "C:\go1.21.4.windows-amd64.zip" -Destination "C:\" -Url "https://storage.googleapis.com/golang/go1.21.4.windows-amd64.zip"

# install git
$client.DownloadFile("https://github.com/git-for-windows/git/releases/download/v2.41.0.windows.1/Git-2.41.0-64-bit.exe", "C:\Git-2.41.0-64-bit.exe")
Start-Process "C:\Git-2.41.0-64-bit.exe" -ArgumentList "/VERYSILENT /LOG=C:\git_install.log /NORESTART /SUPPRESSMSGBOXES" -Wait -NoNewWindow

# install node
$client.DownloadFile("https://nodejs.org/dist/v18.16.1/node-v18.16.1-x64.msi", "C:\NodeSetup.msi")
Start-Process "msiexec" -ArgumentList "/i C:\NodeSetup.msi /quiet" -Wait -NoNewWindow -PassThru

# install python 3.11.4
$client.DownloadFile("https://www.python.org/ftp/python/3.11.4/python-3.11.4-amd64.exe", "C:\python-3.11.4-amd64.exe")
Start-Process "C:\python-3.11.4-amd64.exe" -ArgumentList "/quiet InstallAllUsers=1" -Wait -NoNewWindow -PassThru

# set permanent env vars
[Environment]::SetEnvironmentVariable("GOROOT", "C:\go", "Machine")
[Environment]::SetEnvironmentVariable("PATH", $Env:Path + ";C:\Program Files\Vim\vim80;C:\go\bin;C:\Program Files\Git\cmd;C:\Program Files\nodejs;C:\Program Files\Python311", "Machine")
[Environment]::SetEnvironmentVariable("PATHEXT", $Env:PathExt + ";.PY", "Machine")
[Environment]::SetEnvironmentVariable("GOPATH", "C:\gopath", "Machine")

# set env vars for the currently running process
$env:GOROOT  = "C:\go"
$env:GOPATH  = "C:\gopath"
$env:PATH    = $env:PATH + ";C:\go\bin;C:\gopath\bin;C:\Program Files\Git\cmd;C:\Program Files\Python311"
$env:PATHEXT = $env:PATHEXT + ";.PY"

# get generic-worker and livelog source code (not required, but useful)
Start-Process "go" -ArgumentList "get -t github.com/taskcluster/generic-worker github.com/taskcluster/livelog" -Wait -NoNewWindow -PassThru

# generate ed25519 key
Start-Process C:\generic-worker\generic-worker.exe -ArgumentList "new-ed25519-keypair --file C:\generic-worker\generic-worker-ed25519-signing-key.key" -Wait -NoNewWindow -PassThru

# download cygwin (not required, but useful)
$client.DownloadFile("https://www.cygwin.com/setup-x86_64.exe", "C:\cygwin-setup-x86_64.exe")

# install cygwin
# complete package list: https://cygwin.com/packages/package_list.html
Start-Process "C:\cygwin-setup-x86_64.exe" -ArgumentList "--quiet-mode --wait --root C:\cygwin --site http://cygwin.mirror.constant.com --packages openssh,vim,curl,tar,wget,zip,unzip,diffutils,bzr" -Wait -NoNewWindow -PassThru

# open up firewall for ssh daemon
New-NetFirewallRule -DisplayName "Allow SSH inbound" -Direction Inbound -LocalPort 22 -Protocol TCP -Action Allow

# workaround for https://www.cygwin.com/ml/cygwin/2015-10/msg00036.html
# see:
#   1) https://www.cygwin.com/ml/cygwin/2015-10/msg00038.html
#   2) https://cygwin.com/git/gitweb.cgi?p=cygwin-csih.git;a=blob;f=cygwin-service-installation-helper.sh;h=10ab4fb6d47803c9ffabdde51923fc2c3f0496bb;hb=7ca191bebb52ae414bb2a2e37ef22d94f2658dc7#l2884
$env:LOGONSERVER = "\\" + $env:COMPUTERNAME

# configure sshd (not required, but useful)
Start-Process "C:\cygwin\bin\bash.exe" -ArgumentList "--login -c `"ssh-host-config -y -c 'ntsec mintty' -u 'cygwinsshd' -w 'qwe123QWE!@#'`"" -Wait -NoNewWindow -PassThru

# start sshd
Start-Process "net" -ArgumentList "start cygsshd" -Wait -NoNewWindow -PassThru

# download bash setup script
$client.DownloadFile("https://raw.githubusercontent.com/petemoore/myscrapbook/master/setup.sh", "C:\cygwin\home\Administrator\setup.sh")

# run bash setup script
Start-Process "C:\cygwin\bin\bash.exe" -ArgumentList "--login -c 'chmod a+x setup.sh; ./setup.sh'" -Wait -NoNewWindow -PassThru

# install dependencywalker (useful utility for troubleshooting, not required)
md "C:\DependencyWalker"
Expand-ZIPFile -File "C:\depends22_x64.zip" -Destination "C:\DependencyWalker" -Url "http://dependencywalker.com/depends22_x64.zip"

# install ProcessExplorer (useful utility for troubleshooting, not required)
md "C:\ProcessExplorer"
Expand-ZIPFile -File "C:\ProcessExplorer.zip" -Destination "C:\ProcessExplorer" -Url "https://download.sysinternals.com/files/ProcessExplorer.zip"

# install ProcessMonitor (useful utility for troubleshooting, not required)
md "C:\ProcessMonitor"
Expand-ZIPFile -File "C:\ProcessMonitor.zip" -Destination "C:\ProcessMonitor" -Url "https://download.sysinternals.com/files/ProcessMonitor.zip"

# install Windows 10 SDK
choco install -y windows-sdk-10.0

# install VisualStudio 2019 Community
choco install -y visualstudio2019community --version 16.5.4.0 --package-parameters "--add Microsoft.VisualStudio.Workload.MSBuildTools;Microsoft.VisualStudio.Component.VC.160 --passive --locale en-US"
choco install -y visualstudio2019buildtools --version 16.5.4.0 --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools;includeRecommended --add Microsoft.VisualStudio.Component.VC.160 --add Microsoft.VisualStudio.Component.NuGet.BuildTools --add Microsoft.VisualStudio.Workload.UniversalBuildTools;includeRecommended --add Microsoft.VisualStudio.Workload.NetCoreBuildTools;includeRecommended --add Microsoft.Net.Component.4.5.TargetingPack --add Microsoft.Net.Component.4.6.TargetingPack --add Microsoft.Net.Component.4.7.TargetingPack --passive --locale en-US"

# install gcc for go race detector
choco install -y mingw --version 11.2.0.07112021

# now shutdown, in preparation for creating an image
# Stop-Computer isn't working, also not when specifying -AsJob, so reverting to using `shutdown` command instead
#   * https://www.reddit.com/r/PowerShell/comments/65250s/windows_10_creators_update_stopcomputer_not/dgfofug/?st=j1o3oa29&sh=e0c29c6d
#   * https://support.microsoft.com/en-in/help/4014551/description-of-the-security-and-quality-rollup-for-the-net-framework-4
#   * https://support.microsoft.com/en-us/help/4020459
shutdown -s
