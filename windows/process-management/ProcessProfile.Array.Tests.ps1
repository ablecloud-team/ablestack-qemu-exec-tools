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

$fn=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ProfileEnvironment'},$true)
Invoke-Expression $fn.Extent.Text
function ProfileRegular{}
$environmentFile=[IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllText($environmentFile,'{"PROFILE_SECRET":"reference"}')
    if((ProfileEnvironment $environmentFile)['PROFILE_SECRET'] -cne 'reference'){throw 'Valid environment reference rejected'}
    foreach($invalid in @('{"1invalid":"value"}','{"PROFILE_SECRET":12}','{"PROFILE_SECRET":["value"]}')) {
        [IO.File]::WriteAllText($environmentFile,$invalid);$rejected=$false
        try{$null=ProfileEnvironment $environmentFile}catch{$rejected=$true}
        if(-not $rejected){throw 'Invalid environment reference accepted'}
    }
} finally {
    if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($environmentFile)) -cne [IO.Path]::GetTempPath().TrimEnd('\')){throw 'Unexpected temporary file path'}
    [IO.File]::Delete($environmentFile)
}
Write-Output 'Private environment reference content validation passed'

$fn=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'CheckProfileTaskAcl'},$true)
Invoke-Expression $fn.Extent.Text
CheckProfileTaskAcl 'O:SYG:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)'
$denied=$false
try{CheckProfileTaskAcl 'O:SYG:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GR;;;BU)'}catch{$denied=$true}
if(-not $denied){throw 'Expanded task access accepted'}
Write-Output 'Fixed supervisor task ACL validation passed'
