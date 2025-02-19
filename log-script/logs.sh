#!/bin/bash

DOWN_FILE="/logs/container_down.prom"
HEALTH_FILE="/logs/container_health.prom"
CPU_ALERT_FILE="/logs/container_cpu.prom"
MEMORY_ALERT_FILE="/logs/container_memory.prom"

cleanup() {  
  echo "" > "$DOWN_FILE"
  echo "" > "$HEALTH_FILE"
  echo "" > "$CPU_ALERT_FILE"
  echo "" > "$MEMORY_ALERT_FILE"
}

trap cleanup EXIT

mkdir -p "$(dirname "$DOWN_FILE")" || sudo mkdir -p "$(dirname "$DOWN_FILE")"
mkdir -p "$(dirname "$HEALTH_FILE")" || sudo mkdir -p "$(dirname "$HEALTH_FILE")"
mkdir -p "$(dirname "$CPU_ALERT_FILE")" || sudo mkdir -p "$(dirname "$CPU_ALERT_FILE")"
mkdir -p "$(dirname "$MEMORY_ALERT_FILE")" || sudo mkdir -p "$(dirname "$MEMORY_ALERT_FILE")"

chmod 777 "$(dirname "$DOWN_FILE")" || sudo chmod 777 "$(dirname "$DOWN_FILE")"
chmod 777 "$(dirname "$HEALTH_FILE")" || sudo chmod 777 "$(dirname "$HEALTH_FILE")"
chmod 777 "$(dirname "$CPU_ALERT_FILE")" || sudo chmod 777 "$(dirname "$CPU_ALERT_FILE")"
chmod 777 "$(dirname "$MEMORY_ALERT_FILE")" || sudo chmod 777 "$(dirname "$MEMORY_ALERT_FILE")"

IGNORE_CONTAINERS=("") # Add container names as space-separated-values to be ignored    

docker events --format '{{.Status}} {{.Actor.Attributes.name}}' | while read event container; do
  if [[ "$event" == "stop" ]] && [[ ! " ${IGNORE_CONTAINERS[@]} " =~ " $container " ]]; then          
    echo "Detected stopped container: $container"

    # Fetch last 5 logs
    LOGS=$(docker logs --tail 5 "$container" 2>&1 | sed ':a;N;$!ba;s/\n/\\n/g')

    TIMESTAMP=$(date +%s)

    # Write logs to the file
    echo "container_down{name=\"$container\", logs=\"$LOGS\", stopped_at=\"$TIMESTAMP\"} 1" >> "$DOWN_FILE"

    if [[ $? -eq 0 ]]; then
      echo "Logs written to $DOWN_FILE"
    else
      echo "❌ Failed to write logs to $DOWN_FILE"
    fi
  elif [[ "$event" == "start" ]]; then
    if grep -q "name=\"$container\"" "$DOWN_FILE"; then
      echo "Removing logs for restarted container: $container"
      sed -i "/name=\"$container\"/d" "$DOWN_FILE"  
    fi 
  fi
done &

while true; do
  # To track unhealthy containers
  docker ps --filter "health=unhealthy" --format "{{.Names}}" | while read container; do
    if ! grep -q "name=\"$container\"" "$HEALTH_FILE"; then
      echo "Detected unhealthy container: $container"

      TIMESTAMP=$(date +%s)
      LOGS=$(docker logs --tail 5 "$container" 2>&1 | sed ':a;N;$!ba;s/\n/\\n/g')

      echo "docker_container_health_status{name=\"$container\", status=\"unhealthy\", logs=\"$LOGS\", detected_at=\"$TIMESTAMP\"} 1" >> "$HEALTH_FILE"
      echo "Health status written to $HEALTH_FILE"      
    fi
  done

  # Remove logs for containers that have recovered
  grep -o 'name="[^"]*"' "$HEALTH_FILE" | sed 's/name="//;s/"//' | while read logged_container; do
    if ! docker ps --filter "name=$logged_container" --filter "health=unhealthy" --format "{{.Names}}" | grep -q "$logged_container"; then
      echo "Removing health log for recovered container: $logged_container"
      sed -i "/name=\"$logged_container\"/d" "$HEALTH_FILE"
    fi
  done

  sleep 10  # Check every 10 seconds
done &

CPU_THRESHOLD=80
MEM_THRESHOLD=80

while true; do
  docker stats --no-stream --format "{{.Name}} {{.CPUPerc}} {{.MemPerc}}" | while read container cpu mem; do
    cpu=${cpu%\%}  # Remove % sign
    mem=${mem%\%}
    if (( $(echo "$cpu > $CPU_THRESHOLD" | bc -l) )); then
      if ! grep -q "name=\"$container\"" "$CPU_ALERT_FILE"; then 
        echo "🚨 High CPU Usage: $container is using $cpu% CPU"
        LOGS=$(docker logs --tail 5 "$container" 2>&1 | sed ':a;N;$!ba;s/\n/\\n/g')
        TIMESTAMP=$(date +%s)  
        echo "container_cpu_alert{name=\"$container\", usage=\"$cpu\", logs=\"$LOGS\", detected_at=\"$TIMESTAMP\"} 1" >> "$CPU_ALERT_FILE"
      fi
    else     
      if grep -q "name=\"$container\"" "$CPU_ALERT_FILE"; then
        echo "✅ CPU usage back to normal for $container. Removing alert log."
        sed -i "/name=\"$container\"/d" "$CPU_ALERT_FILE"
      fi
    fi

    if (( $(echo "$mem > $MEM_THRESHOLD" | bc -l) )); then
      if ! grep -q "name=\"$container\"" "$MEMORY_ALERT_FILE"; then      
        echo "🚨 High Memory Usage: $container is using $mem% memory"
        LOGS=$(docker logs --tail 5 "$container" 2>&1 | sed ':a;N;$!ba;s/\n/\\n/g')
        TIMESTAMP=$(date +%s)      
        echo "container_memory_alert{name=\"$container\", usage=\"$mem\", logs=\"$LOGS\", detected_at=\"$TIMESTAMP\"} 1" >> "$MEMORY_ALERT_FILE"
      fi  
    else     
      if grep -q "name=\"$container\"" "$MEMORY_ALERT_FILE"; then
        echo "✅ Memory usage back to normal for $container. Removing alert log."
        sed -i "/name=\"$container\"/d" "$MEMORY_ALERT_FILE"
      fi
    fi
  done

  sleep 10
done 