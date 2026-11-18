# Builds entry-default-unsigned.hap with the DevEco Studio command-line toolchain.
param([string]$Mode = 'debug')
$ErrorActionPreference = 'Stop'
$studioRoot = if ($env:DEVECO_STUDIO_HOME) { $env:DEVECO_STUDIO_HOME } else { (Join-Path $HOME '.t3/tools/DevEcoStudio-26.0.0') }
$env:DEVECO_SDK_HOME = Join-Path $studioRoot 'sdk'
$env:JAVA_HOME = Join-Path $studioRoot 'jbr'
$env:NODE_HOME = Join-Path $studioRoot 'tools/node'
$env:OHPM_HOME = Join-Path $studioRoot 'tools/ohpm'
$env:PATH = "$env:NODE_HOME;$env:OHPM_HOME/bin;$env:JAVA_HOME/bin;$env:PATH"
Push-Location (Join-Path $PSScriptRoot '..')
try {
  & "$studioRoot/tools/node/node.exe" "$studioRoot/tools/hvigor/bin/hvigorw.js" --mode module -p product=default -p module=entry@default -p buildMode=$Mode assembleHap --no-daemon
  exit $LASTEXITCODE
} finally {
  Pop-Location
}
