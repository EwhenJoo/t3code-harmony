# Saves a screenshot of the connected device to the given path (dev helper for design review).
param([Parameter(Mandatory = $true)][string]$Out)
$studioRoot = if ($env:DEVECO_STUDIO_HOME) { $env:DEVECO_STUDIO_HOME } else { (Join-Path $HOME '.t3/tools/DevEcoStudio-26.0.0') }
$hdc = "$studioRoot/sdk/default/openharmony/toolchains/hdc.exe"
& $hdc shell 'snapshot_display -f /data/local/tmp/t3review.jpeg' | Out-Null
& $hdc file recv /data/local/tmp/t3review.jpeg $Out | Out-Null
