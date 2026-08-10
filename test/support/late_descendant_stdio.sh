#!/bin/sh
pid_file="$1"

on_term() {
  sleep 60 &
  child_pid=$!
  printf '%s' "$child_pid" > "$pid_file"
  wait "$child_pid"
}

trap on_term TERM
printf '{"jsonrpc":"2.0","id":1,"result":{"ready":true}}\n'

while :; do
  sleep 1
done
