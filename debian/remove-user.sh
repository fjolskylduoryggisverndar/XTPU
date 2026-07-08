#!/bin/dash

set -e

_USERNAME="unkown"
USERNAME="${1:-$_USERNAME}"

sudo pkill -u "$USERNAME"
sudo deluser --remove-home "$USERNAME"
sudo delgroup "$USERNAME"