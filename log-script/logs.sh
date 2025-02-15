#!/bin/bash

LOG_FILE="/logs/container_logs.prom"

cleanup() {  
  echo "" > "$LOG_FILE"
}

trap cleanup EXIT

mkdir -p "$(dirname "$LOG_FILE")" || sudo mkdir -p "$(dirname "$LOG_FILE")"
chmod 777 "$(dirname "$LOG_FILE")" || sudo chmod 777 "$(dirname "$LOG_FILE")"

remove_logs() {
  local container="$1"
  if grep -q "name=\"$container\"" "$LOG_FILE"; then
    echo "Removing logs for restarted container: $container"
    sed -i "/name=\"$container\"/d" "$LOG_FILE"
  fi  
}

docker events --format '{{.Status}} {{.Actor.Attributes.name}}' | while read event container; do
  if [[ "$event" == "stop" ]]; then
    echo "Detected stopped container: $container"

    # Fetch last 5 logs
    LOGS=$(docker logs --tail 5 "$container" 2>&1 | sed ':a;N;$!ba;s/\n/\\n/g')

    TIMESTAMP=$(date +%s)

    # Write logs to the file
    echo "container_logs{name=\"$container\", logs=\"$LOGS\", stopped_at=\"$TIMESTAMP\"} 1" >> "$LOG_FILE"

    if [[ $? -eq 0 ]]; then
      echo "Logs written to $LOG_FILE"
    else
      echo "❌ Failed to write logs to $LOG_FILE"
    fi
  elif [[ "$event" == "start" ]]; then
      remove_logs "$container"
  fi
done