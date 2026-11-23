#!/bin/bash

if [[ "$1" == "1" || "$1" == "on" || "$1" == "true" ]]; then
  external="true"
elif [[ "$1" == "0" || "$1" == "off" || "$1" == "false" ]]; then
  external="false"
else
  echo "Wrong command argument. Use '$0 on' or '$0 off'."
  exit 1
fi

goose_settings=~/.config/Goose/settings.json

jq ".externalGoosed.enabled = $external"  "$goose_settings" > "$goose_settings.tmp" && mv "$goose_settings.tmp" "$goose_settings"
echo ".externalGoosed.enabled=$(jq -r '.externalGoosed.enabled' "$goose_settings")"
