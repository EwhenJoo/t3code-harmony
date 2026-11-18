# Runs logic tests and user-journey UI tests on the connected emulator/device against the mock T3 server.
#   pwsh ./scripts/test-e2e.ps1 [-NoBuild] [-Class UserJourney]
# Note: clears the app's data on the device first so the journey starts from a fresh install.
param([switch]$NoBuild, [string]$Class = '')
$ErrorActionPreference = 'Stop'
$studioRoot = if ($env:DEVECO_STUDIO_HOME) { $env:DEVECO_STUDIO_HOME } else { (Join-Path $HOME '.t3/tools/DevEcoStudio-26.0.0') }
$hdc = "$studioRoot/sdk/default/openharmony/toolchains/hdc.exe"
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$bundle = 'com.ewhen.t3code'
$env:DEVECO_SDK_HOME = Join-Path $studioRoot 'sdk'
$env:JAVA_HOME = Join-Path $studioRoot 'jbr'
$env:NODE_HOME = Join-Path $studioRoot 'tools/node'
$env:PATH = "$env:NODE_HOME;$studioRoot/tools/ohpm/bin;$env:JAVA_HOME/bin;$env:PATH"

# 1. Mock servers (reuse ones already listening): the main computer, and a second one
#    ("实验室服务器") for the multi-computer journey.
$mocks = @()
if (-not (Get-NetTCPConnection -LocalPort 3790 -State Listen -ErrorAction SilentlyContinue)) {
  $mocks += Start-Process -FilePath node -ArgumentList @("$root/tools/mock-t3/server.mjs", '--port', '3790') -PassThru -WindowStyle Hidden
}
if (-not (Get-NetTCPConnection -LocalPort 3791 -State Listen -ErrorAction SilentlyContinue)) {
  $mocks += Start-Process -FilePath node -ArgumentList @("$root/tools/mock-t3/server.mjs", '--port', '3791', '--profile', 'lab') -PassThru -WindowStyle Hidden
}
if ($mocks.Count -gt 0) { Start-Sleep -Seconds 1 }

try {
  # 2. Build the app and the test package.
  if (-not $NoBuild) {
    Push-Location $root
    try {
      & "$studioRoot/tools/node/node.exe" "$studioRoot/tools/hvigor/bin/hvigorw.js" --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap --no-daemon
      if ($LASTEXITCODE -ne 0) { throw 'app build failed' }
      & "$studioRoot/tools/node/node.exe" "$studioRoot/tools/hvigor/bin/hvigorw.js" --mode module -p product=default -p module=entry@ohosTest -p isOhosTest=true -p buildMode=test assembleHap --no-daemon
      if ($LASTEXITCODE -ne 0) { throw 'test build failed' }
    } finally {
      Pop-Location
    }
  }

  # 3. Install both packages and start from a clean slate.
  $out = Join-Path $root 'entry/build/default/outputs'
  $appHap = Get-ChildItem "$out/default" -Filter 'entry-default-*.hap' | Sort-Object Name -Descending | Select-Object -First 1
  $testHap = Get-ChildItem "$out/ohosTest" -Filter 'entry-ohosTest-*.hap' | Sort-Object Name -Descending | Select-Object -First 1
  & $hdc shell "aa force-stop $bundle" | Out-Null
  $installLog = & $hdc install -r $appHap.FullName
  $installLog
  if (($installLog -join "`n") -match '9568332') {
    # A device-signed build (Push Kit testing) is installed; the unsigned test build cannot replace it.
    # Only ever uninstall on the emulator, never on a phone someone is using.
    $targets = (& $hdc list targets) -join ' '
    if ($targets -notmatch '^\s*127\.0\.0\.1:\d+\s*$') { throw '设备上装的是签名版，且当前连接的不是（唯一的）模拟器；请先断开真机' }
    & $hdc uninstall $bundle | Out-Null
    & $hdc install -r $appHap.FullName
  }
  & $hdc install -r $testHap.FullName
  & $hdc shell "bm clean -n $bundle -d" | Out-Null
  # Files the attachment journey picks in the system file picker (Download on the device).
  & $hdc shell "mkdir -p /storage/media/100/local/files/Docs/Download" | Out-Null
  foreach ($fixture in Get-ChildItem "$root/tools/mock-t3/fixtures") {
    & $hdc file send $fixture.FullName "/storage/media/100/local/files/Docs/Download/$($fixture.Name)" | Out-Null
  }

  # 4. Run.
  $filter = if ($Class) { "-s class $Class" } else { '' }
  $report = & $hdc shell "aa test -b $bundle -m entry_test -s unittest OpenHarmonyTestRunner $filter -s timeout 180000" 2>&1
  $logPath = Join-Path $root 'entry/build/test-report.txt'
  $report | Out-File -Encoding utf8 $logPath
  $report | Select-String -Pattern 'OHOS_REPORT_STATUS: (class|test)=|OHOS_REPORT_STATUS_CODE|OHOS_REPORT_RESULT|stack|Error|AssertException' |
    ForEach-Object { $_.Line }
  Write-Host "Full report: $logPath"
} finally {
  foreach ($m in $mocks) { Stop-Process -Id $m.Id -ErrorAction SilentlyContinue }
}
