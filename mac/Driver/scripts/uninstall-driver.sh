#!/bin/zsh
set -euo pipefail

sudo rm -rf /Library/Audio/Plug-Ins/HAL/CodexMic.driver
sudo killall coreaudiod || true
print "Removed CodexMic.driver"

