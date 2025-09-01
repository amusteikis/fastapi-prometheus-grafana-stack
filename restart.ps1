param([string]$ComposeFile="docker-compose.yml",[string]$ProjectName="grafana-prometheus-stack")
& docker compose -f $ComposeFile -p $ProjectName down
& docker compose -f $ComposeFile -p $ProjectName up -d --remove-orphans
Write-Host "Reiniciado. Ver Prometheus /targets y Grafana /api/health."
