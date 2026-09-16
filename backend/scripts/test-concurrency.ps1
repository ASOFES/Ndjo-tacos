$ErrorActionPreference = 'Stop'
$login = Invoke-RestMethod -Uri http://localhost:3000/auth/login -Method Post -ContentType application/json -Body '{"username":"magasin","password":"admin123"}'
$h = @{ Authorization = "Bearer $($login.token)" }
$est = $login.user.establishmentId
$ings = Invoke-RestMethod -Uri "http://localhost:3000/stock/summary?establishmentId=$est" -Headers $h
$poulet = $ings | Where-Object { $_.code -eq 'ING-POU' } | Select-Object -First 1
$before = $poulet.stockQty
$body = @{
  establishmentId = $est
  productId = $poulet.id
  quantity = 0.2
  destination = 'Cuisine'
  type = 'SORTIE'
  motif = 'Test concurrence FEFO'
} | ConvertTo-Json
$job1 = Start-Job { param($token, $json)
  Invoke-RestMethod -Uri http://localhost:3000/stock/exits -Method Post -Headers @{ Authorization = "Bearer $token" } -ContentType application/json -Body $json
} -ArgumentList $login.token, $body
$job2 = Start-Job { param($token, $json)
  Invoke-RestMethod -Uri http://localhost:3000/stock/exits -Method Post -Headers @{ Authorization = "Bearer $token" } -ContentType application/json -Body $json
} -ArgumentList $login.token, $body
Wait-Job $job1, $job2 | Out-Null
$r1 = Receive-Job $job1
$r2 = Receive-Job $job2
Remove-Job $job1, $job2
$after = (Invoke-RestMethod -Uri "http://localhost:3000/stock/summary?establishmentId=$est" -Headers $h | Where-Object { $_.id -eq $poulet.id }).stockQty
Write-Host "qtyBefore=$before qtyAfter=$after r1=$($r1 | ConvertTo-Json -Compress) r2=$($r2 | ConvertTo-Json -Compress)"
