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

# Disable AV for IO speed
Set-Service "WinDefend" -StartupType Disabled -Status Stopped

# Disable disk indexing
Set-Service "WSearch" -StartupType Disabled -Status Stopped

# install chocolatey package manager
Invoke-Expression ($client.DownloadString('https://chocolatey.org/install.ps1'))

# install Windows 10 SDK
choco install -y windows-sdk-10.0

# install NodeJS LTS v12
choco install -y nodejs --version 12.16.3

# install git
choco install -y git --version 2.26.2

# install python2 as well for node-gyp later
choco install -y python2 --version 2.7.16

# install python3.6
choco install -y python --version 3.6.8

# install 7zip, since msys2 p7zip behaves erratically
choco install -y 7zip --version 19.0

# install VisualStudio 2019 Community
choco install -y visualstudio2019community --version 16.5.4.0 --package-parameters "--add Microsoft.VisualStudio.Workload.MSBuildTools;Microsoft.VisualStudio.Component.VC.160 --passive --locale en-US"
choco install -y visualstudio2019buildtools --version 16.5.4.0 --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools;includeRecommended --add Microsoft.VisualStudio.Component.VC.160 --add Microsoft.VisualStudio.Component.NuGet.BuildTools  --add Microsoft.Net.Component.4.5.TargetingPack --add Microsoft.Net.Component.4.6.TargetingPack --add Microsoft.Net.Component.4.7.TargetingPack --passive --locale en-US"

# vcredist140 required at least for bazel
choco install -y vcredist140 --version 14.16.27027.1

# .Net Framework v4.5.2
choco install -y netfx-4.5.2-devpack --version 4.5.5165101.20180721

# .Net Framework v4.6.2
choco install -y netfx-4.6.2-devpack --version 4.6.01590.20170129

# .Net Framework v4.7.2
choco install -y netfx-4.7.2-devpack --version 4.7.2.20190225

# NuGet
choco install -y nuget.commandline --version 4.9.3

# Carbon for later
choco install -y carbon --version 2.5.0

# Install CUDA v10.1
$client.DownloadFile("https://developer.nvidia.com/compute/cuda/10.1/Prod/local_installers/cuda_10.1.168_425.25_win10.exe", "C:\cuda_10.1.168_425.25_win10.exe")
Start-Process -FilePath "C:\cuda_10.1.168_425.25_win10.exe" -ArgumentList "-s nvcc_10.1 nvprune_10.1 cupti_10.1 gpu_library_advisor_10.1 memcheck_10.1 cublas_10.1 cudart_10.1 cufft_10.1 curand_10.1 cusolver_10.1 cusparse_10.1" -Wait -NoNewWindow

# CuDNN v7.6.0 for CUDA 10.1
#Expand-ZIPFile -File "C:\cudnn-10.1-windows10-x64-v7.6.0.64.zip" -Destination "C:\CUDNN-10.1\" -Url "http://developer.download.nvidia.com/compute/redist/cudnn/v7.6.0/cudnn-10.1-windows10-x64-v7.6.0.64.zip"
md "C:\CUDNN-10.1"
Expand-ZIPFile -File "C:\cudnn-10.1-windows7-x64-v7.6.0.64.zip" -Destination "C:\CUDNN-10.1\" -Url "http://developer.download.nvidia.com/compute/redist/cudnn/v7.6.0/cudnn-10.1-windows7-x64-v7.6.0.64.zip"
cp "C:\CUDNN-10.1\cuda\include\*" "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v10.1\include\"
cp "C:\CUDNN-10.1\cuda\lib\x64\*" "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v10.1\lib\x64\"
cp "C:\CUDNN-10.1\cuda\bin\*" "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v10.1\bin\"

# Create C:\builds and give full access to all users (for hg-shared, tooltool_cache, etc)
md "C:\builds"
$acl = Get-Acl -Path "C:\builds"
$ace = New-Object System.Security.AccessControl.FileSystemAccessRule("Everyone","Full","ContainerInherit,ObjectInherit","None","Allow")
$acl.AddAccessRule($ace)
Set-Acl "C:\builds" $acl

# GrantEveryoneSeCreateSymbolicLinkPrivilege
Start-Process "powershell" -ArgumentList "-command `"& {&'Import-Module' Carbon}`"; `"& {&'Grant-Privilege' -Identity Everyone -Privilege SeCreateSymbolicLinkPrivilege}`"" -Wait -NoNewWindow

# Ensure proper PATH setup
[Environment]::SetEnvironmentVariable("PATH", $Env:Path + ";C:\tools\msys64\usr\bin;C:\Python36;C:\Program Files\Git\bin", "Machine")

# install nssm, neded for generic-worker
Expand-ZIPFile -File "C:\nssm-2.24.zip" -Destination "C:\" -Url "http://www.nssm.cc/release/nssm-2.24.zip"

# download generic-worker
md C:\generic-worker
$client.DownloadFile("https://github.com/taskcluster/taskcluster/releases/download/v32.0.0/generic-worker-multiuser-windows-amd64", "C:\generic-worker\generic-worker.exe")

# install generic-worker, using the batch script suggested in https://github.com/taskcluster/taskcluster-worker-runner/blob/master/docs/windows-services.md
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

# download tc-worker-runner
md C:\worker-runner
$client.DownloadFile("https://github.com/taskcluster/taskcluster-worker-runner/releases/download/v1.0.1/start-worker-windows-amd64", "C:\worker-runner\start-worker.exe")

# install tc-worker-runner using the batch script suggested in https://github.com/taskcluster/taskcluster-worker-runner/blob/master/docs/deployment.md
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
$client.DownloadFile("https://github.com/taskcluster/taskcluster/releases/download/v32.0.0/livelog-windows-amd64", "C:\generic-worker\livelog.exe")

# download taskcluster-proxy
$client.DownloadFile("https://github.com/taskcluster/taskcluster-proxy/releases/download/v5.1.0/taskcluster-proxy-windows-amd64.exe", "C:\generic-worker\taskcluster-proxy.exe")

# configure hosts file for taskcluster-proxy access via http://taskcluster
$HostsFile_Base64 = "IyBDb3B5cmlnaHQgKGMpIDE5OTMtMjAwOSBNaWNyb3NvZnQgQ29ycC4NCiMNCiMgVGhpcyBpcyBhIHNhbXBsZSBIT1NUUyBmaWxlIHVzZWQgYnkgTWljcm9zb2Z0IFRDUC9JUCBmb3IgV2luZG93cy4NCiMNCiMgVGhpcyBmaWxlIGNvbnRhaW5zIHRoZSBtYXBwaW5ncyBvZiBJUCBhZGRyZXNzZXMgdG8gaG9zdCBuYW1lcy4gRWFjaA0KIyBlbnRyeSBzaG91bGQgYmUga2VwdCBvbiBhbiBpbmRpdmlkdWFsIGxpbmUuIFRoZSBJUCBhZGRyZXNzIHNob3VsZA0KIyBiZSBwbGFjZWQgaW4gdGhlIGZpcnN0IGNvbHVtbiBmb2xsb3dlZCBieSB0aGUgY29ycmVzcG9uZGluZyBob3N0IG5hbWUuDQojIFRoZSBJUCBhZGRyZXNzIGFuZCB0aGUgaG9zdCBuYW1lIHNob3VsZCBiZSBzZXBhcmF0ZWQgYnkgYXQgbGVhc3Qgb25lDQojIHNwYWNlLg0KIw0KIyBBZGRpdGlvbmFsbHksIGNvbW1lbnRzIChzdWNoIGFzIHRoZXNlKSBtYXkgYmUgaW5zZXJ0ZWQgb24gaW5kaXZpZHVhbA0KIyBsaW5lcyBvciBmb2xsb3dpbmcgdGhlIG1hY2hpbmUgbmFtZSBkZW5vdGVkIGJ5IGEgJyMnIHN5bWJvbC4NCiMNCiMgRm9yIGV4YW1wbGU6DQojDQojICAgICAgMTAyLjU0Ljk0Ljk3ICAgICByaGluby5hY21lLmNvbSAgICAgICAgICAjIHNvdXJjZSBzZXJ2ZXINCiMgICAgICAgMzguMjUuNjMuMTAgICAgIHguYWNtZS5jb20gICAgICAgICAgICAgICMgeCBjbGllbnQgaG9zdA0KDQojIGxvY2FsaG9zdCBuYW1lIHJlc29sdXRpb24gaXMgaGFuZGxlZCB3aXRoaW4gRE5TIGl0c2VsZi4NCiMJMTI3LjAuMC4xICAgICAgIGxvY2FsaG9zdA0KIwk6OjEgICAgICAgICAgICAgbG9jYWxob3N0DQoNCiMgVXNlZnVsIGZvciBnZW5lcmljLXdvcmtlciB0YXNrY2x1c3Rlci1wcm94eSBpbnRlZ3JhdGlvbg0KIyBTZWUgaHR0cHM6Ly9idWd6aWxsYS5tb3ppbGxhLm9yZy9zaG93X2J1Zy5jZ2k/aWQ9MTQ0OTk4MSNjNg0KMTI3LjAuMC4xICAgICAgICB0YXNrY2x1c3RlciAgICANCg=="
$HostsFile_Content = [System.Convert]::FromBase64String($HostsFile_Base64)
Set-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value $HostsFile_Content -Encoding Byte

# download Windows Server 2003 Resource Kit Tools
$client.DownloadFile("https://download.microsoft.com/download/8/e/c/8ec3a7d8-05b4-440a-a71e-ca3ee25fe057/rktools.exe", "C:\rktools.exe")

# open up firewall for livelog (both PUT and GET interfaces)
New-NetFirewallRule -DisplayName "Allow livelog PUT requests" -Direction Inbound -LocalPort 60022 -Protocol TCP -Action Allow
New-NetFirewallRule -DisplayName "Allow livelog GET requests" -Direction Inbound -LocalPort 60023 -Protocol TCP -Action Allow

# generate OpenPGP key
Start-Process C:\generic-worker\generic-worker.exe -ArgumentList "new-openpgp-keypair --file C:\generic-worker\generic-worker-gpg-signing-key.key" -Wait -NoNewWindow -PassThru -RedirectStandardOutput C:\generic-worker\generate-gpg-signing-key.log -RedirectStandardError C:\generic-worker\generate-gpg-signing-key.err

# generate ed25519 key
Start-Process C:\generic-worker\generic-worker.exe -ArgumentList "new-ed25519-keypair --file C:\generic-worker\generic-worker-ed25519-signing-key.key" -Wait -NoNewWindow -PassThru -RedirectStandardOutput C:\generic-worker\generate-signing-key.log -RedirectStandardError C:\generic-worker\generate-signing-key.err

# install dependencywalker (useful utility for troubleshooting, not required)
md "C:\DependencyWalker"
Expand-ZIPFile -File "C:\depends22_x64.zip" -Destination "C:\DependencyWalker" -Url "http://dependencywalker.com/depends22_x64.zip"

# install ProcessExplorer (useful utility for troubleshooting, not required)
md "C:\ProcessExplorer"
Expand-ZIPFile -File "C:\ProcessExplorer.zip" -Destination "C:\ProcessExplorer" -Url "https://download.sysinternals.com/files/ProcessExplorer.zip"

# install ProcessMonitor (useful utility for troubleshooting, not required)
md "C:\ProcessMonitor"
Expand-ZIPFile -File "C:\ProcessMonitor.zip" -Destination "C:\ProcessMonitor" -Url "https://download.sysinternals.com/files/ProcessMonitor.zip"

# install handle
md "C:\Handle"
Expand-ZIPFile -File "C:\Handle.zip" -Destination "C:\Handle" -Url "https://download.sysinternals.com/files/Handle.zip"

# Free some space
Start-Process "cmd.exe" -ArgumentList "/c del C:\cuda_*" -Wait -NoNewWindow
Start-Process "cmd.exe" -ArgumentList "/c del C:\cudnn*" -Wait -NoNewWindow
Start-Process "cmd.exe" -ArgumentList "/c del C:\CUDNN*" -Wait -NoNewWindow

$computersys = Get-WmiObject Win32_ComputerSystem -EnableAllPrivileges;
$computersys.AutomaticManagedPagefile = $False;
$computersys.Put();
$pagefile = Get-WmiObject -Query "Select * From Win32_PageFileSetting Where Name like '%pagefile.sys'";
$pagefile.InitialSize = 512;
$pagefile.MaximumSize = 2048;
$pagefile.Put();

# NVIDIA Tesla M60 drivers for g3s.xlarge
# Just before reboot because ... it might reboot
$client.DownloadFile("http://us.download.nvidia.com/tesla/426.32/426.32-tesla-desktop-winserver2008-2012r2-64bit-international.exe", "C:\426.32-tesla-desktop-winserver2012r2-64bit-international.exe")
Start-Process -FilePath "C:\426.32-tesla-desktop-winserver2012r2-64bit-international.exe" -ArgumentList "-s -i -noreboot -noeula" -Wait -NoNewWindow -RedirectStandardOutput C:\tesla-install.log -RedirectStandardError C:\tesla-install.err

# now shutdown, in preparation for creating an image
# Stop-Computer isn't working, also not when specifying -AsJob, so reverting to using `shutdown` command instead
#   * https://www.reddit.com/r/PowerShell/comments/65250s/windows_10_creators_update_stopcomputer_not/dgfofug/?st=j1o3oa29&sh=e0c29c6d
#   * https://support.microsoft.com/en-in/help/4014551/description-of-the-security-and-quality-rollup-for-the-net-framework-4
#   * https://support.microsoft.com/en-us/help/4020459
shutdown -s
