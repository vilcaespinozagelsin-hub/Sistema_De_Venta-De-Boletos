$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSCommandPath))
$isAdmin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { $scriptPath=$PSCommandPath; Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$scriptPath`""); exit }
$openssl = 'C:\Program Files\Git\usr\bin\openssl.exe'
if (-not (Test-Path $openssl)) { throw 'No se encontro OpenSSL incluido con Git.' }
$certDir = Join-Path $env:LOCALAPPDATA 'AndesViajes\certs'
New-Item -ItemType Directory -Force -Path $certDir | Out-Null
$caKey = Join-Path $certDir 'root-key.pem'
$caCert = Join-Path $certDir 'root.crt'
$passwordFile = Join-Path $certDir 'password.dpapi'
if (-not (Test-Path $passwordFile)) { $secret = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'); ConvertTo-SecureString $secret -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -LiteralPath $passwordFile -Encoding ASCII }
$secret = (Get-Content -LiteralPath $passwordFile -Raw | ConvertTo-SecureString | ForEach-Object { [Net.NetworkCredential]::new('', $_).Password })
function Invoke-OpenSSL([string[]]$OpenSSLArgs) { & $openssl @OpenSSLArgs; if ($LASTEXITCODE -ne 0) { throw "OpenSSL fallo: $($OpenSSLArgs[0])" } }
if (-not (Test-Path $caCert) -or -not (Test-Path $caKey)) {
  Invoke-OpenSSL @('req','-x509','-newkey','rsa:3072','-sha256','-days','3650','-keyout',$caKey,'-out',$caCert,'-subj','/CN=Andes Viajes LAN Root CA','-addext','basicConstraints=critical,CA:TRUE,pathlen:0','-addext','keyUsage=critical,keyCertSign,cRLSign','-passout',"pass:$secret")
}
$wifi = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.InterfaceAlias -match 'Wi-Fi|WLAN' } | Select-Object -First 1
if (-not $wifi -or -not $wifi.IPv4Address) { throw 'Conecta la computadora a una red Wi-Fi y vuelve a ejecutar este archivo.' }
$ipInfo = $wifi.IPv4Address | Select-Object -First 1; $ip = $ipInfo.IPAddress
$leafKey=Join-Path $certDir 'server-key.pem'; $csr=Join-Path $certDir 'server.csr'; $leafCert=Join-Path $certDir 'server.crt'; $pfx=Join-Path $certDir 'server.pfx'; $ext=Join-Path $certDir 'server-ext.cnf'
@("subjectAltName=IP:$ip,IP:127.0.0.1,DNS:localhost",'extendedKeyUsage=serverAuth','keyUsage=digitalSignature,keyEncipherment','basicConstraints=critical,CA:FALSE') | Set-Content -LiteralPath $ext -Encoding ASCII
Invoke-OpenSSL @('req','-new','-newkey','rsa:2048','-nodes','-keyout',$leafKey,'-out',$csr,'-subj',"/CN=$ip")
Invoke-OpenSSL @('x509','-req','-in',$csr,'-CA',$caCert,'-CAkey',$caKey,'-CAcreateserial','-out',$leafCert,'-days','825','-sha256','-extfile',$ext,'-passin',"pass:$secret")
Invoke-OpenSSL @('pkcs12','-export','-out',$pfx,'-inkey',$leafKey,'-in',$leafCert,'-certfile',$caCert,'-passout',"pass:$secret")
Copy-Item -LiteralPath $caCert -Destination (Join-Path $root 'andes-lan-root.cer') -Force
$broken='FE933AB22824962BADFF6C2E5761E20EE4ABC1E5'
foreach($store in @('Cert:\LocalMachine\My','Cert:\LocalMachine\Root')) { Get-ChildItem $store | Where-Object Thumbprint -eq $broken | Remove-Item -Force }
$caThumb=(Get-FileHash -LiteralPath (Join-Path $root 'andes-lan-root.cer') -Algorithm SHA1).Hash
if (-not (Get-ChildItem Cert:\LocalMachine\Root | Where-Object Thumbprint -eq $caThumb)) { Import-Certificate -FilePath (Join-Path $root 'andes-lan-root.cer') -CertStoreLocation Cert:\LocalMachine\Root | Out-Null }
$leaf=Import-PfxCertificate -FilePath $pfx -CertStoreLocation Cert:\LocalMachine\My -Password (ConvertTo-SecureString $secret -AsPlainText -Force) -Exportable:$false | Select-Object -First 1
if (-not $leaf.HasPrivateKey) { throw 'Windows no pudo cargar la clave privada del certificado HTTPS.' }
$appId='{6D2F17B1-3D96-47EF-9F9E-28723D01C77B}'
foreach($port in @(4180,443)) { $scheme=if($port -eq 4180){'http'}else{'https'}; $url="${scheme}://+:$port/"; $found=netsh http show urlacl "url=$url" 2>&1 | Out-String; if($found -notmatch [regex]::Escape($url)){ netsh http add urlacl "url=$url" "user=$([Security.Principal.WindowsIdentity]::GetCurrent().Name)" listen=yes; if($LASTEXITCODE -ne 0){throw "No se pudo reservar $url"} } }
$binding=netsh http show sslcert ipport=0.0.0.0:443 2>&1 | Out-String
if($binding -match '(?i)certhash|hash de certificado') { if($binding -notmatch [regex]::Escape($appId)){throw 'El puerto 443 ya esta ocupado por otro servicio.'}; netsh http delete sslcert ipport=0.0.0.0:443 | Out-Null }
netsh http add sslcert ipport=0.0.0.0:443 "certhash=$($leaf.Thumbprint)" "appid=$appId" certstorename=MY | Out-Null
if($LASTEXITCODE -ne 0){throw 'Windows no pudo enlazar HTTPS al puerto 443.'}
$prefix=[int]$ipInfo.PrefixLength; $bytes=[Net.IPAddress]::Parse($ip).GetAddressBytes(); $whole=[Math]::Floor($prefix/8); $rem=$prefix%8; if($rem -gt 0){$bytes[$whole]=$bytes[$whole] -band [byte](256-[Math]::Pow(2,8-$rem));$whole++}; for($i=$whole;$i -lt 4;$i++){$bytes[$i]=0}; $network=([Net.IPAddress]::new($bytes)).ToString()+"/$prefix"
foreach($port in @(4180,443)){$name="Andes Viajes WiFi $port";Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue|Remove-NetFirewallRule;New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol TCP -LocalPort $port -RemoteAddress $network -Action Allow -Profile Any|Out-Null}
$fingerprint=(Get-FileHash -LiteralPath (Join-Path $root 'andes-lan-root.cer') -Algorithm SHA256).Hash
Write-Host "HTTPS listo: https://$ip/" -ForegroundColor Green
Write-Host "Certificado publico para instalar una vez en Android: http://$ip`:4180/andes-lan-root.cer"
Write-Host "Huella SHA-256: $fingerprint"
Write-Host 'Reinicia Iniciar sistema local.cmd para activar el enlace HTTPS.'
Read-Host 'Presiona Enter para cerrar'
