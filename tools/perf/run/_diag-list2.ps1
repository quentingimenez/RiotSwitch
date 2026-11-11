$ErrorActionPreference = 'Continue'
$list = New-Object System.Collections.Generic.List[object]
$list.Add([pscustomobject]@{ pid = 1 })
Write-Host ("list.ToArray count=" + $list.ToArray().Count)
Write-Host ("cast count=" + ([object[]]$list).Count)
$al = New-Object System.Collections.ArrayList
[void]$al.Add([pscustomobject]@{ pid = 2 })
Write-Host ("arraylist @ count=" + @($al).Count)
$plain = @()
$plain += [pscustomobject]@{ pid = 3 }
Write-Host ("plain @ count=" + @($plain).Count)
$list2 = New-Object System.Collections.Generic.List[pscustomobject]
$list2.Add([pscustomobject]@{ pid = 4 })
Write-Host ("list2 @ count=" + @($list2).Count)
Write-Host ("list2 cast count=" + ([object[]]$list2).Count)
function f { $l = New-Object System.Collections.Generic.List[object]; $l.Add([pscustomobject]@{pid=5}); return $l }
$x = f
Write-Host ("func x type=" + $x.GetType().FullName)
Write-Host ("func x count=" + @($x).Count)
Write-Host ("func x .Count=" + $x.Count)
