<#
 start.ps1 — Levanta el stack y valida salud (Windows/PowerShell, ASCII-safe)
 Reqs: Docker Desktop ("docker compose"), PowerShell 5.1+ o 7+
#>

param(
  [string]$ComposeFile,
  [string]$ProjectName,
  [string]$PrometheusUrl,
  [string]$GrafanaUrl,
  [string]$AlertmanagerUrl,
  [string]$GrafanaAdminUser,
  [string]$GrafanaAdminPassword,
  [int]$Retries = 60,
  [int]$SleepSecs = 2
)

function Log($msg){ Write-Host ("`n[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $msg) -ForegroundColor Cyan }
function Ok($msg){ Write-Host ("OK: {0}" -f $msg) -ForegroundColor Green }
function Err($msg){ Write-Host ("ERROR: {0}" -f $msg) -ForegroundColor Red }

function Load-DotEnv {
  $envFile = Join-Path (Get-Location) ".env"
  if (Test-Path $envFile) {
    Log "Cargando variables de .env"
    Get-Content $envFile | ForEach-Object {
      if ($_ -match '^\s*#' -or $_ -notmatch '=') { return }
      $kv = $_ -split '=', 2
      $key = $kv[0].Trim()
      $val = $kv[1].Trim()
      if ($key) { [System.Environment]::SetEnvironmentVariable($key, $val, "Process") }
    }
  }
}

Load-DotEnv

if (-not $ComposeFile)   { $ComposeFile   = $env:COMPOSE_FILE }
if (-not $ComposeFile)   { $ComposeFile   = "docker-compose.yml" }

if (-not $ProjectName)   { $ProjectName   = $env:PROJECT_NAME }
if (-not $ProjectName)   { $ProjectName   = "grafana-prometheus-stack" }

if (-not $PrometheusUrl) { $PrometheusUrl = $env:PROMETHEUS_URL }
if (-not $PrometheusUrl) { $PrometheusUrl = "http://localhost:9090" }

if (-not $GrafanaUrl)    { $GrafanaUrl    = $env:GRAFANA_URL }
if (-not $GrafanaUrl)    { $GrafanaUrl    = "http://localhost:3000" }

if (-not $AlertmanagerUrl) { $AlertmanagerUrl = $env:ALERTMANAGER_URL }
if (-not $AlertmanagerUrl) { $AlertmanagerUrl = "http://localhost:9093" }

if (-not $GrafanaAdminUser)     { $GrafanaAdminUser     = $env:GRAFANA_ADMIN_USER }
if (-not $GrafanaAdminPassword) { $GrafanaAdminPassword = $env:GRAFANA_ADMIN_PASSWORD }

function Compose {
  param([Parameter(Mandatory=$true)][string[]]$Args)
  & docker compose -f $ComposeFile -p $ProjectName @Args
}

function Wait-HttpOk {
  param([string]$Name,[string]$BaseUrl,[string]$Path="/",[int]$Expect=200)
  for ($i=1; $i -le $Retries; $i++) {
    try {
      $resp = Invoke-WebRequest -Uri ($BaseUrl + $Path) -Method GET -TimeoutSec 5 -ErrorAction Stop
      if ($resp.StatusCode -eq $Expect) { Ok ("{0} responde {1} en {2}" -f $Name,$Expect,$Path); return $true }
    } catch {}
    Write-Host -NoNewline "."
    Start-Sleep -Seconds $SleepSecs
  }
  Write-Host ""
  Err ("Timeout esperando {0} ({1}{2}) -> {3}" -f $Name,$BaseUrl,$Path,$Expect)
  return $false
}

function Wait-BodyContains {
  param([string]$Name,[string]$BaseUrl,[string]$Path,[string]$Needle)
  for ($i=1; $i -le $Retries; $i++) {
    try {
      $body = Invoke-RestMethod -Uri ($BaseUrl + $Path) -Method GET -TimeoutSec 5 -ErrorAction Stop
      $text = ($body | ConvertTo-Json -Depth 10)
      if ($text -match [Regex]::Escape($Needle)) { Ok ("{0} contiene '{1}' en {2}" -f $Name,$Needle,$Path); return $true }
    } catch {}
    Write-Host -NoNewline "."
    Start-Sleep -Seconds $SleepSecs
  }
  Write-Host ""
  Err ("Timeout esperando contenido '{0}' en {1}{2}" -f $Needle,$BaseUrl,$Path)
  return $false
}

function Validate-PrometheusTargets {
  Log "Validando targets en Prometheus"
  if (-not (Wait-HttpOk -Name "Prometheus" -BaseUrl $PrometheusUrl -Path "/-/healthy" -Expect 200)) { return $false }

  for ($i=1; $i -le $Retries; $i++) {
    try {
      $targets = Invoke-RestMethod -Uri ($PrometheusUrl + "/api/v1/targets") -TimeoutSec 5 -ErrorAction Stop
      $active  = $targets.data.activeTargets
      $total   = @($active).Count
      $upCount = @($active | Where-Object { $_.health -eq "up" }).Count
      if ($total -gt 0) { Ok ("Targets activos: {0}/{1}" -f $upCount,$total); return $true }
    } catch {}
    Write-Host -NoNewline "."
    Start-Sleep -Seconds $SleepSecs
  }
  Write-Host ""
  Err "Timeout: Prometheus sigue sin targets (0/0). Revisar scrape_configs/red."
  return $false
}

function Validate-Alertmanager {
  Log "Validando Alertmanager"
  if (-not (Wait-HttpOk -Name "Alertmanager" -BaseUrl $AlertmanagerUrl -Path "/-/ready" -Expect 200)) { return $false }
  return (Wait-BodyContains -Name "Alertmanager" -BaseUrl $AlertmanagerUrl -Path "/api/v2/status" -Needle '"versionInfo"')
}

function Validate-Grafana {
  Log "Validando Grafana"
  if (-not (Wait-HttpOk -Name "Grafana" -BaseUrl $GrafanaUrl -Path "/api/health" -Expect 200)) { return $false }

  if ($GrafanaAdminUser -and $GrafanaAdminPassword) {
    try {
      $pair = "{0}:{1}" -f $GrafanaAdminUser,$GrafanaAdminPassword
      $b64  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
      $headers = @{ Authorization = "Basic $b64" }

      $health = Invoke-RestMethod -Uri ($GrafanaUrl + "/api/health") -Headers $headers -TimeoutSec 5
      if ($health.database -ne "ok") { Err ("Grafana database health != ok (valor: {0})" -f $health.database); return $false }

      $ds = Invoke-RestMethod -Uri ($GrafanaUrl + "/api/datasources") -Headers $headers -TimeoutSec 5
      $count = @($ds).Count
      Ok ("Grafana responde y tiene {0} datasource(s)" -f $count)
    } catch {
      Err ("No se pudo validar Grafana con credenciales: {0}" -f $_.Exception.Message)
      return $false
    }
  } else {
    Log "Saltando validacion de datasources (definir GRAFANA_ADMIN_USER / GRAFANA_ADMIN_PASSWORD para habilitarla)"
  }
  return $true
}

function Print-Summary {
  Write-Host "================= RESUMEN ================="
  Write-Host ("Stack:    {0}" -f $ProjectName)
  Write-Host ("Compose:  {0}" -f $ComposeFile)
  Write-Host ""
  Write-Host ("Prometheus:   {0}   (/-/healthy, /targets)" -f $PrometheusUrl)
  Write-Host ("Grafana:      {0}   (/login, /api/health)" -f $GrafanaUrl)
  Write-Host ("Alertmanager: {0}   (/-/ready, /#/alerts)" -f $AlertmanagerUrl)
  Write-Host ""
  Write-Host ("Ver estado:    docker compose -f {0} -p {1} ps" -f $ComposeFile,$ProjectName)
  Write-Host ("Logs servicio: docker compose -f {0} -p {1} logs -f <service>" -f $ComposeFile,$ProjectName)
  Write-Host ("Apagar stack:  docker compose -f {0} -p {1} down" -f $ComposeFile,$ProjectName)
  Write-Host "==========================================="
}

# -------------------- MAIN --------------------
try {
  Log "Levantando stack con Docker Compose"
  try { Compose @("pull") | Out-Null } catch {}
  Compose @("up","-d","--remove-orphans") | Out-Null

  Log "Esperando servicios basicos"
  if (-not (Validate-PrometheusTargets)) { Compose @("logs","--tail=200","prometheus"); exit 1 }

  if (-not (Validate-Grafana)) { Compose @("logs","--tail=200","grafana") | Out-Null; exit 1 }

  $services = (Compose @("ps","--services")) -split "`r?`n" | Where-Object { $_ }
  if ($services -contains "alertmanager") {
    if (-not (Validate-Alertmanager)) { Compose @("logs","--tail=200","alertmanager") | Out-Null; exit 1 }
  } else {
    Log "No se encontro servicio 'alertmanager' en el compose; omitiendo validacion"
  }

  Print-Summary
  Ok "Stack listo y validado"
  exit 0
}
catch {
  Err ("Error inesperado: {0}" -f $_.Exception.Message)
  exit 2
}
