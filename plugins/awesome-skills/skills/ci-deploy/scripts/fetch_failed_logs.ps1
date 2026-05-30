$ErrorActionPreference = 'Stop'

function Find-GitBash {
  if ($env:CI_DEPLOY_BASH -and (Test-Path -LiteralPath $env:CI_DEPLOY_BASH)) {
    return $env:CI_DEPLOY_BASH
  }

  $candidates = @(
    'C:\Program Files\Git\bin\bash.exe',
    'C:\Program Files\Git\usr\bin\bash.exe',
    'C:\Program Files (x86)\Git\bin\bash.exe',
    'C:\tools\msys64\usr\bin\bash.exe',
    'C:\msys64\usr\bin\bash.exe'
  )

  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) {
      return $candidate
    }
  }

  $pathBash = Get-Command bash.exe -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Source -notmatch '\\Windows\\System32\\bash.exe$' -and
      $_.Source -notmatch '\\WindowsApps\\bash.exe$'
    } |
    Select-Object -First 1 -ExpandProperty Source

  if ($pathBash) {
    return $pathBash
  }

  throw 'Git Bash was not found. Install Git for Windows, or set CI_DEPLOY_BASH to bash.exe.'
}

function Import-CircleCiToken {
  if ($env:CIRCLECI_TOKEN) {
    $env:CIRCLECI_TOKEN = $env:CIRCLECI_TOKEN.Trim()
    return
  }

  $cliConfig = Join-Path $HOME '.circleci\cli.yml'
  if (-not (Test-Path -LiteralPath $cliConfig)) {
    return
  }

  foreach ($line in Get-Content -LiteralPath $cliConfig) {
    if ($line -match '^\s*token:\s*(.+?)\s*$') {
      $token = $Matches[1].Trim()
      $token = $token.Trim('"')
      $token = $token.Trim("'")
      $env:CIRCLECI_TOKEN = $token
      return
    }
  }
}

$bash = Find-GitBash
Import-CircleCiToken

$script = Join-Path $PSScriptRoot 'fetch_failed_logs.sh'
& $bash $script @args
exit $LASTEXITCODE
