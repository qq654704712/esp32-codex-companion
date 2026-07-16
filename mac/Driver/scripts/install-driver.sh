#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
DRIVER_DIR=${SCRIPT_DIR:h}
SOURCE=${DRIVER_DIR}/build/CodexMic.driver
DESTINATION=/Library/Audio/Plug-Ins/HAL/CodexMic.driver

if [[ ! -d "$SOURCE" ]]; then
  print -u2 "Build the driver first with scripts/build-driver.sh"
  exit 1
fi

sudo mkdir -p /Library/Audio/Plug-Ins/HAL
sudo rm -rf "$DESTINATION"
sudo ditto "$SOURCE" "$DESTINATION"
sudo chown -R root:wheel "$DESTINATION"
sudo chmod -R go-w "$DESTINATION"
sudo killall coreaudiod || true
print "Installed $DESTINATION"

