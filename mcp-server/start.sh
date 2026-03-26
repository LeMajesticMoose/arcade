#!/usr/bin/env bash
cd "$(dirname "$0")"

if [[ ! -f mcp-server.conf ]]; then
  echo "Error: mcp-server.conf not found."
  echo "Copy mcp-server.conf.example to mcp-server.conf and fill in your values."
  exit 1
fi

if ! python3 -c "import fastmcp" 2>/dev/null; then
  echo "Installing fastmcp..."
  pip install fastmcp --quiet
fi

exec python3 server.py
