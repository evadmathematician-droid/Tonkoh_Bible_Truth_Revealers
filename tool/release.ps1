<#
.SYNOPSIS
  Builds a TBTR release and publishes its version to Firebase Remote Config.

.DESCRIPTION
  1. Reads `version: <name>+<code>` from pubspec.yaml.
  2. Builds the release App Bundle (for Play) and APK (for sideloading), and
     copies both to dist\ with the version in the file name.
  3. Publishes latest_version_code = <code> to Remote Config.

  After Google Play shows the release as live, run it again with -Enforce
  (and -SkipBuild). That sets min_version_code / min_required_version, so
  every older install that reads Remote Config is blocked until it updates.
  Builds 30+ installed from Play don't need this: they ask Play directly on
  every start and resume.

.EXAMPLE
  .\tool\release.ps1                     # build + publish latest_version_code
  .\tool\release.ps1 -SkipBuild -Enforce # after Play rollout: block old versions
#>
param(
  [switch]$Enforce,
  [switch]$SkipBuild,
  [string]$Project = 'tonkoh-bible-truth-revea-a7694'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$match = Select-String -Path pubspec.yaml -Pattern '^version:\s*([0-9.]+)\+([0-9]+)\s*$'
if (-not $match) { throw 'pubspec.yaml has no "version: x.y.z+N" line.' }
$versionName = $match.Matches[0].Groups[1].Value
$versionCode = [int]$match.Matches[0].Groups[2].Value
Write-Host "TBTR $versionName (version code $versionCode)" -ForegroundColor Cyan

if (-not $SkipBuild) {
  if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    $env:Path = "E:\APACHE\flutter\bin;$env:Path"
  }
  flutter pub get
  if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
  flutter build appbundle --release
  if ($LASTEXITCODE -ne 0) { throw 'flutter build appbundle failed' }
  flutter build apk --release
  if ($LASTEXITCODE -ne 0) { throw 'flutter build apk failed' }

  New-Item -ItemType Directory -Force dist | Out-Null
  $base = "dist\tbtr-$versionName-$versionCode"
  Copy-Item build\app\outputs\bundle\release\app-release.aab "$base.aab" -Force
  Copy-Item build\app\outputs\flutter-apk\app-release.apk "$base.apk" -Force
  Write-Host "Built $base.aab and $base.apk" -ForegroundColor Green
}

# Merge into the LIVE template so parameters added in the console survive.
$live = Join-Path $env:TEMP "tbtr-remoteconfig-live.json"
Remove-Item $live -ErrorAction SilentlyContinue
firebase remoteconfig:get --project $Project -o $live
$source = if ((Test-Path $live) -and $LASTEXITCODE -eq 0) { $live } else {
  Write-Warning "Couldn't read the live Remote Config; using remoteconfig.template.json."
  'remoteconfig.template.json'
}

$nodeArgs = @('tool/set_remote_config.mjs', $source, 'remoteconfig.template.json',
  "$versionCode", $versionName)
if ($Enforce) { $nodeArgs += '--enforce' }
node @nodeArgs
if ($LASTEXITCODE -ne 0) { throw 'Updating remoteconfig.template.json failed' }

firebase deploy --only remoteconfig --project $Project
if ($LASTEXITCODE -ne 0) {
  Write-Warning @"
Remote Config was NOT published (Firebase CLI not logged in with an account
that can edit project $Project). remoteconfig.template.json is updated; run:
  firebase login:add      (sign in with the TBTR Firebase owner account)
  firebase login:use <that email>
  .\tool\release.ps1 -SkipBuild$(if ($Enforce) { ' -Enforce' })
"@
  exit 1
}
Write-Host 'Remote Config published.' -ForegroundColor Green
if (-not $Enforce) {
  Write-Host "Next: upload dist\tbtr-$versionName-$versionCode.aab to Play Console. When Play shows it live, run:" -ForegroundColor Cyan
  Write-Host '  .\tool\release.ps1 -SkipBuild -Enforce' -ForegroundColor Cyan
}
