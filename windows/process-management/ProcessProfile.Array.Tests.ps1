# Copyright 2026 ABLECLOUD. Apache-2.0.
$ErrorActionPreference='Stop'
$path=Join-Path $PSScriptRoot '../../lib/process/ProcessProfile.ps1'
Add-Type -Path (Join-Path $PSScriptRoot '../../lib/process/AbleProcessAction.dll')
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Invalid profile PowerShell'}
$fn=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ProfileCandidates'},$true)
Invoke-Expression $fn.Extent.Text
function Deadline{}
function Get-CimInstance{return @()}
if(@(ProfileCandidates @{argv=@();executable='C:\fixture.exe';account='S-1-5-18'}).Count -ne 0){throw 'Empty candidates must remain empty'}
Write-Output 'ProfileCandidates empty-array regression passed'
