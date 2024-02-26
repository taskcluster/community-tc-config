# prepare machine to be imaged by using Sysprep
# https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/sysprep-command-line-options?view=windows-11
# taken from GitHub Actions Windows runners
# https://github.com/actions/runner-images/blob/39b838e8fdba4ae9439a37754710dd5610049445/images/windows/templates/windows-2022.pkr.hcl#L452-L458
if( Test-Path $env:SystemRoot\\System32\\Sysprep\\unattend.xml ){ rm $env:SystemRoot\\System32\\Sysprep\\unattend.xml -Force}
& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /mode:vm /quiet /quit
while($true) { $imageState = Get-ItemProperty HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Setup\\State | Select ImageState; if($imageState.ImageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { Write-Output $imageState.ImageState; Start-Sleep -s 10 } else { break } }

# now shutdown, in preparation for creating an image
# Stop-Computer isn't working, also not when specifying -AsJob, so reverting to using `shutdown` command instead
#   * https://www.reddit.com/r/PowerShell/comments/65250s/windows_10_creators_update_stopcomputer_not/dgfofug/?st=j1o3oa29&sh=e0c29c6d
#   * https://support.microsoft.com/en-in/help/4014551/description-of-the-security-and-quality-rollup-for-the-net-framework-4
#   * https://support.microsoft.com/en-us/help/4020459
shutdown -s
