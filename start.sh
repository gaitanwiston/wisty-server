#!/bin/bash

PORT=${PORT:-8080}
HOST=${HOST:-0.0.0.0}

echo "컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴"
echo "Starting Wisty Dart Frog Server"
echo "Host: $HOST"
echo "Port: $PORT"
echo "컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴"

dart_frog dev --hostname $HOST --port $PORT

echo "컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴"
echo "Server stopped."
echo "컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴"
