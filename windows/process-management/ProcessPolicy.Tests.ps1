# Copyright 2026 ABLECLOUD. Apache-2.0. Runs on Windows PowerShell 5.1 and PowerShell 7.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ProcessPolicy.psm1') -Force
$count=0
if ((Get-RpcSet 'guest-shutdown,guest-exec') -cne (Get-RpcSet 'guest-exec,guest-shutdown')) { throw 'QGA reordered filter mismatch' }
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:count++ }
$base='"C:\Program Files\Qemu-ga\qemu-ga.exe" -d --retry-path'
Assert ((Repair-QgaCommand $base) -ceq $base) 'Default policy changed'
$blocked=$base+' --block-rpcs=guest-exec,guest-file-write,guest-shutdown'
Assert ((Repair-QgaCommand $blocked) -ceq ($base+' --block-rpcs=guest-shutdown')) 'Unrelated block not preserved'
$allow=Repair-QgaCommand ($base+' --allow-rpcs=guest-shutdown')
Assert ($allow.Contains('guest-shutdown,guest-exec,')) 'Existing allow entry lost'
Assert ((Repair-QgaCommand $allow) -ceq $allow) 'Repair not idempotent'
Assert ((Repair-QgaCommand ($base+' --allow-rpcs=')).Contains('guest-file-flush')) 'Empty allow not repaired'
foreach ($invalid in @('C:\qemu-ga.exe -d', ($base+' --allow-rpcs=guest-*'), ($base+' --allow-rpcs=guest-ping --allow-rpcs=guest-info'), ($base+' --config=C:\custom.ini'), ($base+' --foo=bar'), ($base+' --allow-rpcs=guest-ping;whoami'))) {
    $failed=$false
    try { $null=Repair-QgaCommand $invalid } catch { $failed=$true }
    Assert $failed 'Ambiguous command accepted'
}
# Inject service operations to validate concurrent-update rejection without touching the host.
& (Get-Module ProcessPolicy) {
    function Get-ItemProperty { [pscustomobject]@{ImagePath='administrator-new-value'} }
    function Set-ItemProperty { throw 'must not write' }
    function Restart-Qga { throw 'must not restart' }
    try { Set-QgaCommand ([pscustomobject]@{Key='unused';Name='unused'}) 'old' 'new'; throw 'Test failed' }
    catch { if ($_.Exception.Message -notlike 'Concurrent administrator*') { throw } }
}
Write-Output "$count parser assertions and concurrent-change guard passed"
