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

function Escape($v){[Security.SecurityElement]::Escape([string]$v)}
$fn=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ProfileTaskDefinition'},$true)
Invoke-Expression $fn.Extent.Text
$xml=ProfileTaskDefinition @{id='00000000-0000-4000-8000-000000000001';cwd=$env:SystemRoot} (Join-Path $env:SystemRoot 'fixture.ps1')
$scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect()
# TASK_VALIDATE_ONLY checks the actual product XML without registering or running.
$null=$scheduler.GetFolder('\').RegisterTask('ABLESTACK-profile-schema-validation',$xml,1,'SYSTEM',$null,5)
Write-Output 'Actual LocalSystem profile task XML validation passed'
