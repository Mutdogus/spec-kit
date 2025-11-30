#!/usr/bin/env pwsh
# Create a new feature
[CmdletBinding()]
param(
    [switch]$Json,
    [string]$ShortName,
    [int]$Number = 0,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FeatureDescription
)
$ErrorActionPreference = 'Stop'

# Show help if requested
if ($Help) {
    Write-Host "Usage: ./create-new-feature.ps1 [-Json] [-ShortName <name>] [-Number N] <feature description>"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Json               Output in JSON format"
    Write-Host "  -ShortName <name>   Provide a custom short name (2-4 words) for the branch"
    Write-Host "  -Number N           Specify branch number manually (overrides auto-detection)"
    Write-Host "  -Help               Show this help message"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  ./create-new-feature.ps1 'Add user authentication system' -ShortName 'user-auth'"
    Write-Host "  ./create-new-feature.ps1 'Implement OAuth2 integration for API'"
    exit 0
}

# Check if feature description provided
if (-not $FeatureDescription -or $FeatureDescription.Count -eq 0) {
    Write-Error "Usage: ./create-new-feature.ps1 [-Json] [-ShortName <name>] <feature description>"
    exit 1
}

$featureDesc = ($FeatureDescription -join ' ').Trim()

# Resolve repository root. Prefer git information when available, but fall back
# to searching for repository markers so the workflow still functions in repositories that
# were initialized with --no-git.
function Find-RepositoryRoot {
    param(
        [string]$StartDir,
        [string[]]$Markers = @('.git', '.specify')
    )
    $current = Resolve-Path $StartDir
    while ($true) {
        foreach ($marker in $Markers) {
            if (Test-Path (Join-Path $current $marker)) {
                return $current
            }
        }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) {
            # Reached filesystem root without finding markers
            return $null
        }
        $current = $parent
    }
}

function Get-ProjectContext {
    param(
        [string]$RepoRoot,
        [string]$CurrentDir
    )
    
    # Check for .specify/.current-project file
    $currentProjectFile = Join-Path $RepoRoot '.specify/.current-project'
    if (Test-Path $currentProjectFile) {
        $currentProject = Get-Content $currentProjectFile -Raw | ForEach-Object { $_.Trim() }
        if ($currentProject) {
            return $currentProject
        }
    }
    
    # Check if we're in a project-specific specs directory
    $relativePath = $CurrentDir.Substring($RepoRoot.Length).TrimStart('\', '/')
    if ($relativePath -match '^specs/([^/]+)') {
        $potentialProject = $matches[1]
        $projectFile = Join-Path $RepoRoot ".specify/projects/$potentialProject.yaml"
        if (Test-Path $projectFile) {
            return $potentialProject
        }
    }
    
    # Fallback: try to detect from existing specs structure
    $specsDir = Join-Path $RepoRoot 'specs'
    if (Test-Path $specsDir) {
        $subdirs = Get-ChildItem -Path $specsDir -Directory | Where-Object {
            $projectFile = Join-Path $RepoRoot ".specify/projects/$($_.Name).yaml"
            Test-Path $projectFile
        }
        if ($subdirs.Count -gt 0) {
            return $subdirs[0].Name
        }
    }
    
    return $null
}

function Get-ProjectConfig {
    param(
        [string]$RepoRoot,
        [string]$ProjectId
    )
    
    $projectFile = Join-Path $RepoRoot ".specify/projects/$ProjectId.yaml"
    if (-not (Test-Path $projectFile)) {
        return $null
    }
    
    # Extract configuration values using simple parsing
    # This is a basic YAML parser for our specific structure
    $content = Get-Content $projectFile -Raw
    
    $rangeStart = if ($content -match 'range_start:\s*(\d+)') { [int]$matches[1] } else { 1 }
    $rangeEnd = if ($content -match 'range_end:\s*(\d+)') { [int]$matches[1] } else { 999 }
    $scheme = if ($content -match 'scheme:\s*(\w+)') { $matches[1] } else { "per-project" }
    
    # Return as a custom object
    return [PSCustomObject]@{
        RangeStart = $rangeStart
        RangeEnd = $rangeEnd
        Scheme = $scheme
    }
}

function Get-ProjectSpecsDir {
    param(
        [string]$RepoRoot,
        [string]$ProjectId
    )
    
    if ($ProjectId) {
        return Join-Path $RepoRoot "specs\$ProjectId"
    } else {
        return Join-Path $RepoRoot 'specs'
    }
}

function Get-HighestNumberFromSpecs {
    param([string]$SpecsDir)
    
    $highest = 0
    if (Test-Path $SpecsDir) {
        Get-ChildItem -Path $SpecsDir -Directory | ForEach-Object {
            if ($_.Name -match '^(\d+)') {
                $num = [int]$matches[1]
                if ($num -gt $highest) { $highest = $num }
            }
        }
    }
    return $highest
}

function Get-HighestNumberFromBranches {
    param()
    
    $highest = 0
    try {
        $branches = git branch -a 2>$null
        if ($LASTEXITCODE -eq 0) {
            foreach ($branch in $branches) {
                # Clean branch name: remove leading markers and remote prefixes
                $cleanBranch = $branch.Trim() -replace '^\*?\s+', '' -replace '^remotes/[^/]+/', ''
                
                # Extract feature number if branch matches pattern ###-*
                if ($cleanBranch -match '^(\d+)-') {
                    $num = [int]$matches[1]
                    if ($num -gt $highest) { $highest = $num }
                }
            }
        }
    } catch {
        # If git command fails, return 0
        Write-Verbose "Could not check Git branches: $_"
    }
    return $highest
}

function Get-NextBranchNumber {
    param(
        [string]$ShortName,
        [string]$SpecsDir,
        [string]$ProjectId = $null,
        [object]$ProjectConfig = $null
    )
    
    # Fetch all remotes to get latest branch info (suppress errors if no remotes)
    try {
        git fetch --all --prune 2>$null | Out-Null
    } catch {
        # Ignore fetch errors
    }
    
    # Find remote branches matching the pattern using git ls-remote
    $remoteBranches = @()
    try {
        $remoteRefs = git ls-remote --heads origin 2>$null
        if ($remoteRefs) {
            $remoteBranches = $remoteRefs | Where-Object { $_ -match "refs/heads/(\d+)-$([regex]::Escape($ShortName))$" } | ForEach-Object {
                if ($_ -match "refs/heads/(\d+)-") {
                    [int]$matches[1]
                }
            }
        }
    } catch {
        # Ignore errors
    }
    
    # Check local branches
    $localBranches = @()
    try {
        $allBranches = git branch 2>$null
        if ($allBranches) {
            $localBranches = $allBranches | Where-Object { $_ -match "^\*?\s*(\d+)-$([regex]::Escape($ShortName))$" } | ForEach-Object {
                if ($_ -match "(\d+)-") {
                    [int]$matches[1]
                }
            }
        }
    } catch {
        # Ignore errors
    }
    
    # Check specs directory
    $specDirs = @()
    if (Test-Path $SpecsDir) {
        try {
            $specDirs = Get-ChildItem -Path $SpecsDir -Directory | Where-Object { $_.Name -match "^(\d+)-$([regex]::Escape($ShortName))$" } | ForEach-Object {
                if ($_.Name -match "^(\d+)-") {
                    [int]$matches[1]
                }
            }
        } catch {
            # Ignore errors
        }
    }
    
    # Combine all sources and get the highest number
    $maxNum = 0
    foreach ($num in ($remoteBranches + $localBranches + $specDirs)) {
        # Filter by project range if project-aware
        if ($ProjectId -and $ProjectConfig) {
            if ($num -ge $ProjectConfig.RangeStart -and $num -le $ProjectConfig.RangeEnd) {
                if ($num -gt $maxNum) {
                    $maxNum = $num
                }
            }
        } else {
            if ($num -gt $maxNum) {
                $maxNum = $num
            }
        }
    }
    
    # Return next number, respecting project range
    if ($ProjectId -and $ProjectConfig) {
        # If no existing features in range, start from range start
        if ($maxNum -lt $ProjectConfig.RangeStart) {
            return $ProjectConfig.RangeStart
        } else {
            $nextNum = $maxNum + 1
            # Ensure we don't exceed the range
            if ($nextNum -gt $ProjectConfig.RangeEnd) {
                Write-Error "Project '$ProjectId' has exhausted its number range ($($ProjectConfig.RangeStart:000)-$($ProjectConfig.RangeEnd:000))"
                exit 1
            }
            return $nextNum
        }
    } else {
        return $maxNum + 1
    }
}

function ConvertTo-CleanBranchName {
    param([string]$Name)
    
    return $Name.ToLower() -replace '[^a-z0-9]', '-' -replace '-{2,}', '-' -replace '^-', '' -replace '-$', ''
}
$fallbackRoot = (Find-RepositoryRoot -StartDir $PSScriptRoot)
if (-not $fallbackRoot) {
    Write-Error "Error: Could not determine repository root. Please run this script from within the repository."
    exit 1
}

try {
    $repoRoot = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0) {
        $hasGit = $true
    } else {
        throw "Git not available"
    }
} catch {
    $repoRoot = $fallbackRoot
    $hasGit = $false
}

Set-Location $repoRoot

# Detect project context
$currentDir = Get-Location
$projectId = Get-ProjectContext -RepoRoot $repoRoot -CurrentDir $currentDir

# Load project configuration if available
$projectConfig = $null
if ($projectId) {
    $projectConfig = Get-ProjectConfig -RepoRoot $repoRoot -ProjectId $projectId
    if ($projectConfig) {
        Write-Host "[specify] Using project: $projectId (range: $($projectConfig.RangeStart:000)-$($projectConfig.RangeEnd:000))" -ForegroundColor Yellow
    } else {
        Write-Warning "[specify] Warning: Could not load configuration for project '$projectId'"
        $projectId = $null
    }
}

# Set specs directory based on project context
$specsDir = Get-ProjectSpecsDir -RepoRoot $repoRoot -ProjectId $projectId
New-Item -ItemType Directory -Path $specsDir -Force | Out-Null

# Function to generate branch name with stop word filtering and length filtering
function Get-BranchName {
    param([string]$Description)
    
    # Common stop words to filter out
    $stopWords = @(
        'i', 'a', 'an', 'the', 'to', 'for', 'of', 'in', 'on', 'at', 'by', 'with', 'from',
        'is', 'are', 'was', 'were', 'be', 'been', 'being', 'have', 'has', 'had',
        'do', 'does', 'did', 'will', 'would', 'should', 'could', 'can', 'may', 'might', 'must', 'shall',
        'this', 'that', 'these', 'those', 'my', 'your', 'our', 'their',
        'want', 'need', 'add', 'get', 'set'
    )
    
    # Convert to lowercase and extract words (alphanumeric only)
    $cleanName = $Description.ToLower() -replace '[^a-z0-9\s]', ' '
    $words = $cleanName -split '\s+' | Where-Object { $_ }
    
    # Filter words: remove stop words and words shorter than 3 chars (unless they're uppercase acronyms in original)
    $meaningfulWords = @()
    foreach ($word in $words) {
        # Skip stop words
        if ($stopWords -contains $word) { continue }
        
        # Keep words that are length >= 3 OR appear as uppercase in original (likely acronyms)
        if ($word.Length -ge 3) {
            $meaningfulWords += $word
        } elseif ($Description -match "\b$($word.ToUpper())\b") {
            # Keep short words if they appear as uppercase in original (likely acronyms)
            $meaningfulWords += $word
        }
    }
    
    # If we have meaningful words, use first 3-4 of them
    if ($meaningfulWords.Count -gt 0) {
        $maxWords = if ($meaningfulWords.Count -eq 4) { 4 } else { 3 }
        $result = ($meaningfulWords | Select-Object -First $maxWords) -join '-'
        return $result
    } else {
        # Fallback to original logic if no meaningful words found
        $result = ConvertTo-CleanBranchName -Name $Description
        $fallbackWords = ($result -split '-') | Where-Object { $_ } | Select-Object -First 3
        return [string]::Join('-', $fallbackWords)
    }
}

# Generate branch name
if ($ShortName) {
    # Use provided short name, just clean it up
    $branchSuffix = ConvertTo-CleanBranchName -Name $ShortName
} else {
    # Generate from description with smart filtering
    $branchSuffix = Get-BranchName -Description $featureDesc
}

# Determine branch number
if ($Number -eq 0) {
    if ($hasGit) {
        # Check existing branches on remotes (project-aware)
        $Number = Get-NextBranchNumber -ShortName $branchSuffix -SpecsDir $specsDir -ProjectId $projectId -ProjectConfig $projectConfig
    } else {
        # Fall back to local directory check (project-aware)
        $highest = Get-HighestNumberFromSpecs -SpecsDir $specsDir
        
        # Apply project range constraints if project-aware
        if ($projectId -and $projectConfig) {
            if ($highest -lt $projectConfig.RangeStart) {
                $Number = $projectConfig.RangeStart
            } else {
                $Number = $highest + 1
            }
            
            # Ensure we don't exceed the range
            if ($Number -gt $projectConfig.RangeEnd) {
                Write-Error "Project '$projectId' has exhausted its number range ($($projectConfig.RangeStart:000)-$($projectConfig.RangeEnd:000))"
                exit 1
            }
        } else {
            $Number = $highest + 1
        }
    }
}

$featureNum = ('{0:000}' -f $Number)
$branchName = "$featureNum-$branchSuffix"

# GitHub enforces a 244-byte limit on branch names
# Validate and truncate if necessary
$maxBranchLength = 244
if ($branchName.Length -gt $maxBranchLength) {
    # Calculate how much we need to trim from suffix
    # Account for: feature number (3) + hyphen (1) = 4 chars
    $maxSuffixLength = $maxBranchLength - 4
    
    # Truncate suffix
    $truncatedSuffix = $branchSuffix.Substring(0, [Math]::Min($branchSuffix.Length, $maxSuffixLength))
    # Remove trailing hyphen if truncation created one
    $truncatedSuffix = $truncatedSuffix -replace '-$', ''
    
    $originalBranchName = $branchName
    $branchName = "$featureNum-$truncatedSuffix"
    
    Write-Warning "[specify] Branch name exceeded GitHub's 244-byte limit"
    Write-Warning "[specify] Original: $originalBranchName ($($originalBranchName.Length) bytes)"
    Write-Warning "[specify] Truncated to: $branchName ($($branchName.Length) bytes)"
}

if ($hasGit) {
    try {
        git checkout -b $branchName | Out-Null
    } catch {
        Write-Warning "Failed to create git branch: $branchName"
    }
} else {
    Write-Warning "[specify] Warning: Git repository not detected; skipped branch creation for $branchName"
}

$featureDir = Join-Path $specsDir $branchName
New-Item -ItemType Directory -Path $featureDir -Force | Out-Null

# Resolve template path with project-aware fallback
$template = $null
if ($projectId) {
    # Check for project-specific template first
    $projectTemplate = Join-Path $repoRoot ".specify/templates/projects/$projectId/spec-template.md"
    if (Test-Path $projectTemplate) {
        $template = $projectTemplate
    }
}

# Fall back to global template
if (-not $template) {
    $globalTemplate = Join-Path $repoRoot '.specify/templates/spec-template.md'
    if (Test-Path $globalTemplate) {
        $template = $globalTemplate
    }
}

$specFile = Join-Path $featureDir 'spec.md'
if ($template) { 
    Copy-Item $template $specFile -Force 
    Write-Host "[specify] Using template: $template" -ForegroundColor Yellow
} else { 
    New-Item -ItemType File -Path $specFile | Out-Null 
    Write-Warning "[specify] Warning: No template found, created empty spec file"
}

# Set the SPECIFY_FEATURE environment variable for the current session
$env:SPECIFY_FEATURE = $branchName
if ($projectId) {
    $env:SPECIFY_PROJECT = $projectId
}

if ($Json) {
    $obj = [PSCustomObject]@{ 
        BRANCH_NAME = $branchName
        SPEC_FILE = $specFile
        FEATURE_NUM = $featureNum
        PROJECT_ID = $projectId
        HAS_GIT = $hasGit
    }
    $obj | ConvertTo-Json -Compress
} else {
    Write-Output "BRANCH_NAME: $branchName"
    Write-Output "SPEC_FILE: $specFile"
    Write-Output "FEATURE_NUM: $featureNum"
    if ($projectId) {
        Write-Output "PROJECT_ID: $projectId"
        Write-Output "SPECIFY_PROJECT environment variable set to: $projectId"
    }
    Write-Output "HAS_GIT: $hasGit"
    Write-Output "SPECIFY_FEATURE environment variable set to: $branchName"
}

