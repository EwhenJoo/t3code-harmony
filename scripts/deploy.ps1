# Builds, installs and launches the app, then optionally saves a screenshot.
#   pwsh ./scripts/deploy.ps1                         # emulator or the only connected device
#   pwsh ./scripts/deploy.ps1 -Target <phone-ip>:<port> -Shot shot.jpeg
# Real phones need a signed HAP: the build is signed with scripts/sign.ps1 (小白调试助手 profile).
# The emulator accepts the unsigned HAP as is.
param([string]$Target = $env:HDC_TARGET, [string]$Shot = '', [switch]$NoBuild)
$ErrorActionPreference = 'Stop'
$studioRoot = if ($env:DEVECO_STUDIO_HOME) { $env:DEVECO_STUDIO_HOME } else { (Join-Path $HOME '.t3/tools/DevEcoStudio-26.0.0') }
$hdc = "$studioRoot/sdk/default/openharmony/toolchains/hdc.exe"
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$bundle = 'com.ewhen.t3code'

if (-not $Target) {
  $targets = @(& $hdc list targets | Where-Object { $_ -match '\S' -and $_ -notmatch 'Empty' })
  if ($targets.Count -ne 1) { throw "连接了 $($targets.Count) 台设备，请用 -Target 指定：$($targets -join ', ')" }
  $Target = $targets[0].Trim()
}
$isEmulator = $Target -like '127.0.0.1:*'

if (-not $NoBuild) {
  & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build.ps1')
  if ($LASTEXITCODE -ne 0) { throw 'build failed' }
}
$outDir = Join-Path $root 'entry/build/default/outputs/default'
$hap = Join-Path $outDir 'entry-default-unsigned.hap'
if (-not $isEmulator) {
  $signed = Join-Path $outDir 'entry-default-device-signed.hap'
  & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'sign.ps1') -In $hap -Out $signed
  if ($LASTEXITCODE -ne 0) { throw 'signing failed' }
  $hap = $signed
}

& $hdc -t $Target install -r $hap
& $hdc -t $Target shell "aa force-stop $bundle" | Out-Null
& $hdc -t $Target shell "aa start -a EntryAbility -b $bundle"
if ($Shot -ne '') {
  Start-Sleep -Seconds 6
  & $hdc -t $Target shell 'snapshot_display -f /data/local/tmp/t3shot.jpeg' | Out-Null
  & $hdc -t $Target file recv /data/local/tmp/t3shot.jpeg ([IO.Path]::GetFullPath($Shot)) | Out-Null
}
