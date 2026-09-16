$ErrorActionPreference = 'Stop'
$base = 'http://localhost:3000'

function Login($username) {
  $res = Invoke-RestMethod -Uri "$base/auth/login" -Method Post -ContentType 'application/json' -Body (@{ username = $username; password = 'admin123' } | ConvertTo-Json)
  return $res
}

function Api($token, $method, $path, $body = $null) {
  $headers = @{ Authorization = "Bearer $token" }
  if ($null -eq $body) {
    return Invoke-RestMethod -Uri "$base$path" -Method $method -Headers $headers
  }
  return Invoke-RestMethod -Uri "$base$path" -Method $method -Headers $headers -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 8)
}

$admin = Login 'admin'
$estId = $admin.user.establishmentId
Write-Host "ADMIN est=$estId"

$customers = Api $admin.token Get "/customers?establishmentId=$estId"
$jean = $customers | Where-Object { $_.name -like '*Jean*' } | Select-Object -First 1
$addr = $jean.addresses | Select-Object -First 1
$products = Api $admin.token Get "/catalog/products?establishmentId=$estId&kind=VENTE"
$tacos = $products | Where-Object { $_.code -eq 'TAC-POU' } | Select-Object -First 1
Write-Host "Client=$($jean.name) addr=$($addr.label) tacos=$($tacos.id)"

$order = Api $admin.token Post '/orders' @{
  establishmentId = $estId
  type = 'LIVRAISON'
  customerId = $jean.id
  addressId = $addr.id
  zoneId = $addr.zoneId
  items = @(@{ productId = $tacos.id; quantity = 1 })
}
Write-Host "ORDER $($order.number) otpHiddenOnCreate=$($null -ne $order.otp) token=$($order.trackingToken)"

$assigned = Api $admin.token Post "/delivery/$($order.id)/assign"
Write-Host "ASSIGN driver=$($assigned.driver.name) pickup=$($assigned.pickedUpAt)"

$started = Api $admin.token Post "/delivery/$($order.id)/start"
Write-Host "START departed=$($started.departedAt)"

$otpSend = Api $admin.token Post "/delivery/$($order.id)/send-otp"
Write-Host "OTP sent=$($otpSend.sent) channel=$($otpSend.channel) staff=$($otpSend.staffOtp) hint=$($otpSend.otpHint)"

$trackBefore = Invoke-RestMethod -Uri "$base/track/$($order.trackingToken)"
Write-Host "TRACK before GPS hasMap=$($null -ne $trackBefore.mapUrl) hasEta=$($null -ne $trackBefore.eta) loc=$($null -ne $trackBefore.location) reception=$($trackBefore.receptionCode)"

try {
  Api $admin.token Post "/delivery/$($order.id)/deliver" @{ otp = '0000' }
  Write-Host 'FAIL: wrong OTP accepted'
} catch {
  Write-Host "WRONG OTP refused: $($_.ErrorDetails.Message)"
}

$gps = Api $admin.token Post '/delivery/location' @{
  latitude = -11.672
  longitude = 27.486
  orderId = $order.id
}
Write-Host "GPS etaMin=$($gps.eta.minutes) km=$($gps.eta.distanceKm)"

$listed = Api $admin.token Get "/delivery?establishmentId=$estId"
$current = $listed | Where-Object { $_.id -eq $order.id } | Select-Object -First 1
Write-Host "LIST eta=$($null -ne $current.eta) otpLeaked=$($null -ne $current.otp) loc=$($null -ne $current.location)"

$track = Invoke-RestMethod -Uri "$base/track/$($order.trackingToken)"
Write-Host "TRACK after GPS hasMap=$($null -ne $track.mapUrl) hasEta=$($null -ne $track.eta) loc=$($null -ne $track.location) minutes=$($track.eta.minutes)"

$arrived = Api $admin.token Post "/delivery/$($order.id)/arrive"
Write-Host "ARRIVE at=$($arrived.arrivedAt)"

$proof = Api $admin.token Post "/delivery/$($order.id)/deliver" @{
  otp = $otpSend.staffOtp
  proofSignature = 'Jean Mwamba'
  proofPhotoUrl = 'https://picsum.photos/seed/ndjo-proof/400/300'
  latitude = -11.664
  longitude = 27.479
}
Write-Host "DELIVER status=$($proof.status) by=$($proof.proof.deliveredBy.name) otpAt=$($proof.otpVerifiedAt) photo=$($proof.proof.photoUrl)"

$trackDone = Invoke-RestMethod -Uri "$base/track/$($order.trackingToken)"
Write-Host "TRACK done proof=$($null -ne $trackDone.proof) receptionHidden=$($null -eq $trackDone.receptionCode) duration=$($trackDone.durationMinutes)"

$history = Api $admin.token Get "/delivery/drivers/$($assigned.driver.id)"
Write-Host "DRIVER photo=$($null -ne $history.photoUrl) courses=$($history.stats.total) delivered=$($history.stats.delivered) lastDur=$($history.courses[0].durationMinutes)"

$magasin = Login 'magasin'
$ings = Api $magasin.token Get "/stock/summary?establishmentId=$estId"
$poulet = $ings | Where-Object { $_.code -eq 'ING-POU' } | Select-Object -First 1
$places = Invoke-RestMethod -Uri "$base/public/establishments"
$dest = $places | Where-Object { $_.id -ne $estId } | Select-Object -First 1
$qtyBefore = $poulet.stockQty
Write-Host "TRANSFER product=$($poulet.name) qtyBefore=$qtyBefore dest=$($dest.name)"

$trf = Api $magasin.token Post '/stock/transfers' @{
  sourceId = $estId
  destId = $dest.id
  productId = $poulet.id
  quantity = 1
}
$afterCreate = (Api $magasin.token Get "/stock/summary?establishmentId=$estId" | Where-Object { $_.id -eq $poulet.id }).stockQty
Write-Host "TRF $($trf.number) status=$($trf.status) qtyAfterCreate=$afterCreate"

$shipped = Api $magasin.token Post "/stock/transfers/$($trf.id)/ship"
$afterShip = (Api $magasin.token Get "/stock/summary?establishmentId=$estId" | Where-Object { $_.id -eq $poulet.id }).stockQty
Write-Host "SHIP status=$($shipped.status) lots=$($shipped.sourceLots | ConvertTo-Json -Compress) qtyAfterShip=$afterShip"

$received = Api $admin.token Post "/stock/transfers/$($trf.id)/receive" @{ location = 'Dépôt destination' }
Write-Host "RECV status=$($received.status) destLot=$($received.lotId)"

$destLots = Api $admin.token Get "/stock/lots?establishmentId=$($dest.id)"
$newLot = $destLots | Where-Object { $_.id -eq $received.lotId } | Select-Object -First 1
Write-Host "DEST LOT $($newLot.number) qty=$($newLot.qtyCurrent) product=$($newLot.product.name)"
