$ErrorActionPreference = 'Continue'
$out = New-Object System.Collections.Generic.List[object]
$out.Add([pscustomobject]@{ pid = 1; command_line = 'a' })
Write-Host ("list_count=" + $out.Count)
$r = $out
Write-Host ("concat1=" + @($r).Count)
$arr = @($r)
Write-Host ("concat2=" + $arr.Count)
$c = @($out)
Write-Host ("concat3=" + $c.Count)
Write-Host ("ret_count=" + @($out).Count)
