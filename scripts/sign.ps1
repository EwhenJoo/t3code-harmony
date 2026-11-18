# Signs HAPs for a real device with the AGC debug certificate that 小白调试助手 created, and the debug
# profile made for com.ewhen.t3code in AppGallery Connect (it carries the Push Kit capability and lists
# the phone and the emulator).
#
# 小白调试助手 keeps its key and certificate in Documents/hap_installer. This script
# reads them in place at run time, so no keys or passwords are copied into the repository. Its key
# is PEM; hap-sign-tool needs PKCS#12, so a throwaway keystore with a random password is created in
# a temp folder for the duration of the run and deleted afterwards.
# Usage: pwsh ./scripts/sign.ps1 -In a.hap,b.hap -Out a-signed.hap,b-signed.hap
param(
  [Parameter(Mandatory = $true)][string[]]$In,
  [Parameter(Mandatory = $true)][string[]]$Out,
  [string]$Store = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'hap_installer'),
  [string]$Bundle = 'com.ewhen.t3code',
  # Kept outside the repository; download it again from AGC → Profile (T3Code-debug-push) if missing.
  [string]$Profile = (Join-Path $HOME '.t3/signing/t3code/T3Code-debug-push.p7b')
)
$ErrorActionPreference = 'Stop'
if ($In.Count -ne $Out.Count) { throw '-In and -Out need the same number of files' }
$studioRoot = if ($env:DEVECO_STUDIO_HOME) { $env:DEVECO_STUDIO_HOME } else { (Join-Path $HOME '.t3/tools/DevEcoStudio-26.0.0') }
$java = "$studioRoot/jbr/bin/java.exe"
$signTool = "$studioRoot/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
$openssl = if ($env:OPENSSL) { $env:OPENSSL } else { 'C:/Program Files/Git/usr/bin/openssl.exe' }

$configPath = Join-Path $Store 'signConfig.json'
if (-not (Test-Path $configPath)) {
  throw "没有找到 $configPath。先用小白调试助手对 $Bundle 做一次「开始调试(自动签名)」。"
}
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$profileFile = $Profile
if (-not (Test-Path $profileFile)) {
  throw "没有找到 $profileFile。在 AppGallery Connect → Profile 下载 T3Code-debug-push 放到这里。"
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('t3-sign-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
  $keystore = $config.keystoreFile
  $alias = $config.keyAlias
  $password = $config.keystorePwd
  if ($keystore -notmatch '\.(p12|pfx|jks)$') {
    # PEM key from 小白调试助手 → temporary PKCS#12 that only lives in $work.
    $password = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16))
    $keystore = Join-Path $work 'device.p12'
    $env:T3_SIGN_PASS = $password
    & $openssl pkcs12 -export -inkey $config.keystoreFile -in $config.certPath -name $alias `
      -passout env:T3_SIGN_PASS -out $keystore 2>&1 | Out-Null
    Remove-Item Env:T3_SIGN_PASS
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $keystore)) { throw '无法把小白调试助手的私钥转换为 p12' }
  }
  for ($i = 0; $i -lt $In.Count; $i++) {
    $log = & $java -jar $signTool sign-app -mode localSign -signAlg SHA256withECDSA `
      -keyAlias $alias -keyPwd $password -keystoreFile $keystore -keystorePwd $password `
      -appCertFile $config.certPath -profileFile $profileFile `
      -inFile ([IO.Path]::GetFullPath($In[$i])) -outFile ([IO.Path]::GetFullPath($Out[$i])) 2>&1
    if ($LASTEXITCODE -ne 0) {
      $log | Select-String 'ERROR' | ForEach-Object { Write-Host $_.Line }
      throw "签名失败：$($In[$i])"
    }
    Write-Host "signed $($Out[$i])"
  }
} finally {
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
