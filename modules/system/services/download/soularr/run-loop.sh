#!/bin/sh
set -eu

interval=$1
shift

while :; do
  "$@"
  sleep "$interval"
done
