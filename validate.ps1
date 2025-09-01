param(
  [string]$PrometheusUrl="http://localhost:9090",
  [string]$GrafanaUrl="http://localhost:3000",
  [string]$AlertmanagerUrl="http://localhost:9093",
  [string]$GrafanaAdminUser,$GrafanaAdminPassword,
  [int]$Retries=40,[int]$SleepSecs=2
)

function ok($m){Write-Host "OK: $m" -f Green}
function waitHttp($name,$url,$path="/",[int]$code=200){
  for($i=0;$i -lt $Retries;$i++){
    try{$r=Invoke-WebRequest -Uri ($url+$path) -TimeoutSec 5 -ErrorAction Stop;if($r.StatusCode -eq $code){ok "$name $code $path";return $true}}catch{}
    Start-Sleep -s $SleepSecs
  };throw "Timeout $name $path"
}

waitHttp "Prometheus" $PrometheusUrl "/-/healthy" 200
$tg = Invoke-RestMethod ($PrometheusUrl+"/api/v1/targets")
$active = @($tg.data.activeTargets)
if($active.Count -lt 1){throw "Prometheus sin targets"}
ok ("Targets {0}/{1}" -f (@($active | ?{$_.health -eq 'up'}).Count),$active.Count)

waitHttp "Grafana" $GrafanaUrl "/api/health" 200
if($GrafanaAdminUser -and $GrafanaAdminPassword){
  $b64=[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${GrafanaAdminUser}:${GrafanaAdminPassword}"))
  $h=@{Authorization="Basic $b64"}
  $ds=Invoke-RestMethod -Uri ($GrafanaUrl+"/api/datasources") -Headers $h
  ok ("Grafana datasources: {0}" -f (@($ds).Count))
}

waitHttp "Alertmanager" $AlertmanagerUrl "/-/ready" 200
$st=Invoke-RestMethod ($AlertmanagerUrl+"/api/v2/status")
if(-not $st.versionInfo){throw "Alertmanager sin status"}; ok "Alertmanager status OK"