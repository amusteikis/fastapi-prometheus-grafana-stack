param([string]$ComposeFile="docker-compose.yml",[string]$ProjectName="grafana-prometheus-stack")
& docker compose -f $ComposeFile -p $ProjectName down
 
