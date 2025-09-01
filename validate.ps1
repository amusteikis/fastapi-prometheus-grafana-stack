param(
  [string]$PrometheusUrl    = "http://localhost:9090",
  [string]$GrafanaUrl       = "http://localhost:3000",
  [string]$AlertmanagerUrl  = "http://localhost:9093",
  [string]$GrafanaAdminUser,
  [string]$GrafanaAdminPassword,
  [int]$Retries = 40,
  [int]$SleepSecs = 2
)

# ------------------ Utils ------------------
function Log($m){ Write-Host ("[validate] {0}" -f $m) -ForegroundColor Cyan }
function Ok($m){ Write-Host ("OK: {0}" -f $m) -ForegroundColor Green }
function Err($m){ Write-Host ("ERROR: {0}" -f $m) -ForegroundColor Red }

function Wait-HttpOk {
  param([string]$Name,[string]$BaseUrl,[string]$Path="/",[int]$Expect=200)
  for ($i=1; $i -le $Retries; $i++) {
    try {
      $resp = Invoke-WebRequest -Uri ($BaseUrl + $Path) -TimeoutSec 5 -ErrorAction Stop
      if ($resp.StatusCode -eq $Expect) { Ok ("{0} {1} {2}" -f $Name,$Expect,$Path); return $true }
    } catch {}
    Start-Sleep -Seconds $SleepSecs
  }
  throw ("Timeout {0} {1}" -f $Name,$Path)
}

# ------------------ Prometheus ------------------
function Validate-Prometheus {
  Log "Prometheus health"
  Wait-HttpOk -Name "Prometheus" -BaseUrl $PrometheusUrl -Path "/-/healthy" -Expect 200 | Out-Null

  Log "Esperando targets UP en Prometheus"
  $upCount = 0; $total = 0
  for ($i=1; $i -le $Retries; $i++) {
    try {
      $tg = Invoke-RestMethod -Uri ($PrometheusUrl + "/api/v1/targets") -TimeoutSec 5 -ErrorAction Stop
      $active = @($tg.data.activeTargets)
      $total = $active.Count
      $upCount = @($active | Where-Object { $_.health -eq "up" }).Count
      if ($total -gt 0) { break }
    } catch {}
    Start-Sleep -Seconds $SleepSecs
  }
  if ($total -lt 1) { throw "Prometheus sin targets" }
  Ok ("Targets {0}/{1}" -f $upCount,$total)
}

# ------------------ Grafana ------------------
function Validate-Grafana {
  Log "Grafana health"
  Wait-HttpOk -Name "Grafana" -BaseUrl $GrafanaUrl -Path "/api/health" -Expect 200 | Out-Null

  if ($GrafanaAdminUser -and $GrafanaAdminPassword) {
    Log "Validando datasources de Grafana con credenciales"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $GrafanaAdminUser,$GrafanaAdminPassword)))
    $headers = @{ Authorization = "Basic $b64" }

    $count = -1
    for ($i=1; $i -le [Math]::Max(5,$Retries/4); $i++) {
      try {
        $ds = Invoke-RestMethod -Uri ($GrafanaUrl + "/api/datasources") -Headers $headers -TimeoutSec 5 -ErrorAction Stop
        $count = @($ds).Count
        break
      } catch {}
      Start-Sleep -Seconds $SleepSecs
    }
    if ($count -lt 0) { throw "Grafana datasources no disponibles" }
    Ok ("Grafana datasources: {0}" -f $count)
  } else {
    Log "Saltando validacion de datasources (sin credenciales)"
  }
}

# ------------------ Alertmanager ------------------
function Validate-Alertmanager {
  Log "Alertmanager ready"
  Wait-HttpOk -Name "Alertmanager" -BaseUrl $AlertmanagerUrl -Path "/-/ready" -Expect 200 | Out-Null

  Log "Validando status de Alertmanager"
  $ok = $false
  for ($i=1; $i -le [Math]::Max(5,$Retries/4); $i++) {
    try {
      $st = Invoke-RestMethod -Uri ($AlertmanagerUrl + "/api/v2/status") -TimeoutSec 5 -ErrorAction Stop
      if ($st.versionInfo) { $ok = $true; break }
    } catch {}
    Start-Sleep -Seconds $SleepSecs
  }
  if (-not $ok) { throw "Alertmanager sin status" }
  Ok "Alertmanager status OK"
}

# ------------------ Main ------------------
try {
  Validate-Prometheus
  Validate-Grafana
  Validate-Alertmanager
  Ok "Validacion completa"
  exit 0
}
catch {
  Err $_.Exception.Message
  exit 1
}
