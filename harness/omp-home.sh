#!/bin/sh
# Creates an isolated omp home whose only provider is the fake server on 127.0.0.1:<port>.
#
#   harness/omp-home.sh <home-dir> <port> [extra-config.yml]
#
# Writes <home-dir>/.omp/agent/models.yml (provider `fake`: `fake-1`, `fake-think` with reasoning) and
# <home-dir>/.omp/agent/config.yml. A top-level key of extra-config.yml replaces the same top-level key
# of the base config; other keys are added. Prints nothing on success.
set -eu

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
	echo "usage: $0 <home-dir> <port> [extra-config.yml]" >&2
	exit 2
fi
home=$1
port=$2
extra=${3:-}
case $port in
'' | *[!0-9]*)
	echo "port must be a number: $port" >&2
	exit 2
	;;
esac
if [ -n "$extra" ] && [ ! -f "$extra" ]; then
	echo "no such file: $extra" >&2
	exit 2
fi

agent=$home/.omp/agent
mkdir -p "$agent"

cat >"$agent/models.yml" <<EOF
providers:
  fake:
    baseUrl: http://127.0.0.1:$port/v1
    apiKey: fake-key
    api: openai-completions
    models:
      - id: fake-1
        name: Fake One
        reasoning: false
        input: [text]
        contextWindow: 128000
        maxTokens: 8192
      - id: fake-think
        name: Fake Think
        reasoning: true
        input: [text]
        contextWindow: 128000
        maxTokens: 8192
EOF

# Off: network checks (updates, marketplace), host side effects (sleep assertions), processes the
# fixtures do not need (LSP servers), stream rules that could interrupt scripted output (TTSR), and the
# keyless Apple on-device model, which omp offers on Apple silicon Macs with Apple Intelligence (measured with
# omp 18.4.12 on macOS 27), so the fake provider stays the only one. RPC mode already disables title generation,
# advisor and memory.
base='startup:
  checkUpdate: false
marketplace:
  autoUpdate: "off"
power:
  sleepPrevention: "off"
lsp:
  enabled: false
ttsr:
  enabled: false
dev:
  autoqa: false
disabledProviders:
  - apple'

if [ -z "$extra" ]; then
	printf '%s\n' "$base" >"$agent/config.yml"
	exit 0
fi

printf '%s\n' "$base" | awk -v extra="$extra" '
	BEGIN {
		while ((getline line < extra) > 0) {
			if (line ~ /^[^[:space:]#-][^:]*:/) { sub(/:.*/, "", line); replaced[line] = 1 }
		}
	}
	/^[^[:space:]#-][^:]*:/ { key = $0; sub(/:.*/, "", key); skip = (key in replaced) }
	!skip { print }
' >"$agent/config.yml"
cat "$extra" >>"$agent/config.yml"
