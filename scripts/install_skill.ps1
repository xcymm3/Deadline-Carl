[CmdletBinding()]
param(
  [string]$CodexHome = '',
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$SkillRoot = Split-Path -Parent $PSScriptRoot
$SkillName = 'deadline-carl'
$LegacySkillName = 'codex-durable-loop'

if (-not $CodexHome) {
  $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
}

$CodexHome = [System.IO.Path]::GetFullPath($CodexHome)
$skillsDirectory = Join-Path $CodexHome 'skills'
$destination = Join-Path $skillsDirectory $SkillName
$legacyDestination = Join-Path $skillsDirectory $LegacySkillName
$staging = Join-Path $skillsDirectory ".$SkillName.installing.$PID.$([Guid]::NewGuid().ToString('N'))"

New-Item -ItemType Directory -Path $skillsDirectory -Force | Out-Null

if (Test-Path -LiteralPath $legacyDestination) {
  if (-not $Force) {
    throw "Legacy skill is installed at $legacyDestination. Use -Force to migrate it while preserving a backup."
  }
}

if (Test-Path -LiteralPath $destination) {
  if (-not $Force) {
    throw "Skill is already installed at $destination. Use -Force to replace it while preserving a backup."
  }
}

New-Item -ItemType Directory -Path $staging -Force | Out-Null
$items = @('SKILL.md', 'LICENSE', 'NOTICE', 'agents', 'assets', 'references', 'scripts')
try {
  # Stage the complete package before moving an existing installation. This is
  # required when this installer is run from the installed skill itself.
  foreach ($item in $items) {
    $source = Join-Path $SkillRoot $item
    if (-not (Test-Path -LiteralPath $source)) {
      throw "Missing skill package item: $source"
    }
    Copy-Item -LiteralPath $source -Destination $staging -Recurse -Force
  }

  if (Test-Path -LiteralPath $legacyDestination) {
    $legacyBackup = "$legacyDestination.backup.$(Get-Date -Format 'yyyyMMddHHmmss')"
    Move-Item -LiteralPath $legacyDestination -Destination $legacyBackup
    Write-Output "Legacy installation moved to $legacyBackup"
  }

  if (Test-Path -LiteralPath $destination) {
    $backup = "$destination.backup.$(Get-Date -Format 'yyyyMMddHHmmss')"
    Move-Item -LiteralPath $destination -Destination $backup
    Write-Output "Existing installation moved to $backup"
  }

  Move-Item -LiteralPath $staging -Destination $destination
} finally {
  if (Test-Path -LiteralPath $staging) {
    Remove-Item -LiteralPath $staging -Recurse -Force
  }
}
Write-Output "Installed $SkillName to $destination"
Write-Output 'Restart Codex so the new skill metadata is discovered.'
