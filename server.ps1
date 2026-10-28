$ErrorActionPreference = 'Continue'
$root = [IO.Path]::GetFullPath((Split-Path -Parent $MyInvocation.MyCommand.Path))
$configPath = Join-Path $root 'credentials.local.json'
$statePath = Join-Path $root 'shared-state.local.json'
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add('http://+:4180/')
$listener.Prefixes.Add('https://+:443/')
try { $listener.Start() } catch { Write-Host 'No se pudo iniciar el servidor local en los puertos 4180/443.'; Write-Host $_.Exception.Message; Read-Host 'Presiona Enter para cerrar'; exit 1 }
Write-Host 'Sistema Andes listo. HTTP redirige a HTTPS en el puerto 443.'
$mime = @{ '.html'='text/html; charset=utf-8'; '.css'='text/css; charset=utf-8'; '.js'='text/javascript; charset=utf-8'; '.png'='image/png'; '.jpg'='image/jpeg'; '.svg'='image/svg+xml'; '.cer'='application/pkix-cert' }
function Read-AndesState {
  if (-not (Test-Path -LiteralPath $statePath)) { return @{bookings=@();holds=@{};activity=@()} }
  $raw = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
  $holdMap = @{}
  if ($raw.holds) { foreach ($property in $raw.holds.PSObject.Properties) { $holdMap[$property.Name]=$property.Value } }
  $cleanBookings = @($raw.bookings | Where-Object { $null -ne $_ })
  $cleanActivity = @($raw.activity | Where-Object { $null -ne $_ })
  return @{bookings=$cleanBookings;holds=$holdMap;activity=$cleanActivity}
}
function Save-AndesState($data) { $json=ConvertTo-Json -InputObject $data -Depth 20; $temporary=$statePath+'.tmp'; [IO.File]::WriteAllText($temporary,$json,[Text.UTF8Encoding]::new($false)); Move-Item -LiteralPath $temporary -Destination $statePath -Force }
function Send-AndesJson($code,$data) { $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $data -Depth 20 -Compress)); $response.StatusCode=$code; $response.ContentType='application/json; charset=utf-8'; $response.ContentLength64=$bytes.Length; $response.OutputStream.Write($bytes,0,$bytes.Length) }
while ($listener.IsListening) {
  try { $context = $listener.GetContext() } catch { break }
  $request = $context.Request
  $response = $context.Response
  try {
    if ($request.Url.Scheme -eq 'http' -and $request.Url.AbsolutePath -ne '/andes-lan-root.cer') {
      $response.StatusCode = 308
      $response.RedirectLocation = "https://$($request.Url.Host)$($request.Url.PathAndQuery)"
      continue
    }
    if ($request.Url.AbsolutePath -eq '/api/shared-state') {
      $state = Read-AndesState
      $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      foreach ($key in @($state.holds.Keys)) { if ([double]$state.holds[$key].until -le $now) { $state.holds.Remove($key) } }
      foreach ($booking in $state.bookings) { if ($booking.status -eq 'Reservado' -and $booking.expiresAt -and [double]$booking.expiresAt -le $now) { $booking.status='Vencido'; $state.holds.Remove("$($booking.trip)-$($booking.seat)") } }
      $stateExists = Test-Path -LiteralPath $statePath
      if ($request.HttpMethod -eq 'GET') { if ($stateExists) { Save-AndesState $state }; Send-AndesJson 200 @{ok=$true;exists=$stateExists;state=$state}; continue }
      if ($request.HttpMethod -ne 'POST') { Send-AndesJson 405 @{error='Metodo no permitido.'}; continue }
      $reader = New-Object System.IO.StreamReader($request.InputStream,$request.ContentEncoding)
      $inputData = $reader.ReadToEnd() | ConvertFrom-Json
      $action = [string]$inputData.action
      if ($action -eq 'initialize') {
        if (-not (Test-Path -LiteralPath $statePath)) { $initialBookings=@($inputData.bookings | Where-Object { $null -ne $_ }); $initialActivity=@($inputData.activity | Where-Object { $null -ne $_ }); $state=@{bookings=$initialBookings;holds=@{};activity=$initialActivity}; Save-AndesState $state }
      } elseif ($action -eq 'hold') {
        $tripId=[string]$inputData.trip; $seat=[int]$inputData.seat; $owner=[string]$inputData.owner; $key="$tripId-$seat"
        $blocked=@($state.bookings | Where-Object { $_.trip -eq $tripId -and [int]$_.seat -eq $seat -and $_.status -ne 'Cancelado' -and $_.status -ne 'Vencido' -and ($_.status -ne 'Reservado' -or [double]$_.expiresAt -gt $now) })
        if ($blocked.Count -gt 0 -or ($state.holds.ContainsKey($key) -and [double]$state.holds[$key].until -gt $now -and $state.holds[$key].owner -ne $owner)) { Save-AndesState $state; Send-AndesJson 409 @{error='Ese asiento ya esta ocupado o reservado.';state=$state}; continue }
        $state.holds[$key]=@{owner=$owner;until=$now+600000}
      } elseif ($action -eq 'release') {
        $key="$($inputData.trip)-$([int]$inputData.seat)"; if ($state.holds.ContainsKey($key) -and $state.holds[$key].owner -eq [string]$inputData.owner) { $state.holds.Remove($key) }
      } elseif ($action -eq 'book') {
        $tickets=@($inputData.tickets); $owner=[string]$inputData.owner; $problem=$null
        foreach ($ticket in $tickets) { $key="$($ticket.trip)-$([int]$ticket.seat)"; $blocked=@($state.bookings | Where-Object { $_.trip -eq [string]$ticket.trip -and [int]$_.seat -eq [int]$ticket.seat -and $_.status -ne 'Cancelado' -and $_.status -ne 'Vencido' -and ($_.status -ne 'Reservado' -or [double]$_.expiresAt -gt $now) }); if ($blocked.Count -gt 0 -or -not $state.holds.ContainsKey($key) -or $state.holds[$key].owner -ne $owner -or [double]$state.holds[$key].until -le $now) { $problem='Un asiento ya no esta disponible. Actualiza el mapa e intenta de nuevo.'; break } }
        if ($problem) { Send-AndesJson 409 @{error=$problem;state=$state}; continue }
        foreach ($ticket in $tickets) { $state.bookings=@($state.bookings)+@($ticket); $key="$($ticket.trip)-$([int]$ticket.seat)"; if ($ticket.status -eq 'Reservado') { $state.holds[$key]=@{owner='reserved';until=[double]$ticket.expiresAt} } else { $state.holds.Remove($key); $state.activity=@(@{passenger=$ticket.passenger;route=$ticket.route;channel='Web';price=$ticket.price;time=(Get-Date).ToString('HH:mm')})+@($state.activity) } }
        $state.activity=@($state.activity | Select-Object -First 30)
      } elseif ($action -eq 'complete') {
        $found=$false; $updated=@($inputData.ticket); $oldCode=[string]$inputData.oldCode
        foreach ($booking in $state.bookings) { if ($booking.code -eq $oldCode -and $booking.status -eq 'Reservado' -and [double]$booking.expiresAt -gt $now) { $found=$true } }
        if (-not $found) { Send-AndesJson 409 @{error='La reserva ya vencio o fue completada en otro dispositivo.';state=$state}; continue }
        $newBookings=@(); foreach ($booking in $state.bookings) { if ($booking.code -eq $oldCode) { $newBookings+=@($updated[0]) } else { $newBookings+=@($booking) } }; $state.bookings=$newBookings; $state.holds.Remove("$($updated[0].trip)-$($updated[0].seat)"); $state.activity=@(@{passenger=$updated[0].passenger;route=$updated[0].route;channel='Web';price=$updated[0].price;time=(Get-Date).ToString('HH:mm')})+@($state.activity); $state.activity=@($state.activity | Select-Object -First 30)
      } elseif ($action -eq 'cancel' -or $action -eq 'board') {
        $code=[string]$inputData.code; $found=$false
        foreach ($booking in $state.bookings) { if ($booking.code -eq $code) { $found=$true; if ($action -eq 'cancel') { $booking.status='Cancelado'; $state.holds.Remove("$($booking.trip)-$($booking.seat)") } else { $booking.boarded=[bool]$inputData.boarded } } }
        if (-not $found) { Send-AndesJson 404 @{error='No se encontro el boleto.';state=$state}; continue }
      } else { Send-AndesJson 400 @{error='Accion compartida no reconocida.'}; continue }
      Save-AndesState $state
      Send-AndesJson 200 @{ok=$true;state=$state}
      continue
    }    if ($request.HttpMethod -eq 'POST' -and $request.Url.AbsolutePath -eq '/api/print-ticket') {
      $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
      $inputData = $reader.ReadToEnd() | ConvertFrom-Json
      $ticket = $inputData.ticket
      $required = @('code','passenger','dni','route','date','depart','bus','seat','price')
      foreach ($key in $required) { if ($null -eq $ticket.$key -or [string]::IsNullOrWhiteSpace([string]$ticket.$key)) { throw 'Faltan datos del boleto.' } }
      if (-not (Test-Path -LiteralPath $configPath)) { throw 'No se encuentra credentials.local.json.' }
      $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
      $externalId = [string]$inputData.external_id
      if ([string]::IsNullOrWhiteSpace($externalId)) { $externalId = [string]$ticket.code }
      $externalId = [regex]::Replace($externalId, '[^a-zA-Z0-9._-]', '-')
      if ($externalId.Length -gt 120) { $externalId = $externalId.Substring(0,120) }
      $seatNumber = ([string]$ticket.seat).PadLeft(2,'0')
      $contentLines = @('ANDES DEL PERU','BOLETO DE VIAJE','--------------------------------',"Ruta: $($ticket.route)","Fecha: $($ticket.date)  Salida: $($ticket.depart)","Bus: $($ticket.bus)  Asiento: $seatNumber", "Pasajero: $($ticket.passenger)","DNI: $($ticket.dni)  Edad: $($ticket.age)",('Precio: S/ {0:N2}' -f [double]$ticket.price),"Codigo: $($ticket.code)",'--------------------------------','Presentar este boleto al abordar.')
      $job = @{ source='Sistema Andes de Boletos'; external_id=$externalId; title="Boleto $($ticket.code)"; content=($contentLines -join "`n"); copies=1 }
      $headers = @{ 'OAI-Sites-Authorization'="Bearer $($config.siteAccessToken)"; 'Authorization'="Bearer $($config.submitToken)" }
      $result = Invoke-RestMethod -Uri $config.apiJobsUrl -Method Post -ContentType 'application/json' -Headers $headers -Body ($job | ConvertTo-Json -Depth 8) -TimeoutSec 15
      $out = @{ ok=$true; duplicate=[bool]$result.duplicate; job=$result.job }
      $bytes = [Text.Encoding]::UTF8.GetBytes(($out | ConvertTo-Json -Depth 10 -Compress))
      $response.StatusCode = 200
      $response.ContentType = 'application/json; charset=utf-8'
      $response.OutputStream.Write($bytes,0,$bytes.Length)
      continue
    }
    if ($request.HttpMethod -ne 'GET' -and $request.HttpMethod -ne 'HEAD') { $response.StatusCode=405; continue }
    $relative = $request.Url.AbsolutePath.TrimStart('/')
    if ($relative -in @('credentials.local.json','lan-access.key','shared-state.local.json','server.ps1','.gitignore','Iniciar sistema local.cmd','Configurar acceso WiFi.ps1')) { $response.StatusCode=404; continue }
    if ([string]::IsNullOrWhiteSpace($relative)) { $relative='index.html' }
    $file = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not $file.StartsWith(($root + [IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { $response.StatusCode=404; continue }
    $extension = [IO.Path]::GetExtension($file).ToLowerInvariant()
    if ($mime.ContainsKey($extension)) { $response.ContentType=$mime[$extension] } else { $response.ContentType='application/octet-stream' }
    $response.Headers['Cache-Control']='no-cache'
    if ($request.HttpMethod -eq 'GET') { $bytes=[IO.File]::ReadAllBytes($file); $response.ContentLength64=$bytes.Length; $response.OutputStream.Write($bytes,0,$bytes.Length) }
  } catch {
    $message = $_.Exception.Message
    if ($message -match '401|403|Unauthorized|Forbidden') { $message='La central rechazo las credenciales o el acceso.' }
    $response.StatusCode=502
    $response.ContentType='application/json; charset=utf-8'
    $bytes=[Text.Encoding]::UTF8.GetBytes((@{error=$message} | ConvertTo-Json -Compress))
    try { $response.OutputStream.Write($bytes,0,$bytes.Length) } catch {}
  } finally { try { $response.Close() } catch {} }
}
