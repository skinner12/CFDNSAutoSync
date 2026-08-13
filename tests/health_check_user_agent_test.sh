#!/usr/bin/env bash
#
# Verifies that every health-check HTTP request identifies itself with the
# project's User-Agent.
#
# Background: an anonymous curl request (default User-Agent, no Referer) is a
# common bot-filter signature. A reverse proxy in front of a monitored domain
# dropped exactly that shape with `return 444`; the CDN in front reported the
# empty reply as HTTP 502, so the updater read a perfectly healthy site as
# offline and flapped DNS between both origins every few minutes. Sending a
# recognisable User-Agent keeps the checks out of those filters and makes them
# identifiable in origin access logs.
#
# Usage: bash tests/health_check_user_agent_test.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TARGET="$SCRIPT_DIR/cloudflare_dns_updater.sh"

TESTS_RUN=0
TESTS_FAILED=0
TESTS_SKIPPED=0

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    printf '  ok      %s\n' "$1"
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL    %s\n            %s\n' "$1" "$2"
}

skip() {
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    printf '  skip    %s (%s)\n' "$1" "$2"
}

WORKDIR=$(mktemp -d)
SRV_PID=""
cleanup() {
    [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

# Sourcing only defines the functions; the entry point is guarded by a
# BASH_SOURCE check so the updater does not run here.
# shellcheck source=/dev/null
source "$TARGET"

# Keep the real log untouched. Read by log_message in the sourced script, which
# ShellCheck cannot see from here.
# shellcheck disable=SC2034
LOG_FILE="$WORKDIR/test.log"

EXPECTED_UA="CFDNSAutoSync/${VERSION} (+health-check)"

printf 'Health-check User-Agent\n'

# ─── 1. The constant exists and has the expected value ────────────────────────

if [[ -n "${HEALTH_CHECK_USER_AGENT:-}" ]]; then
    if [[ "$HEALTH_CHECK_USER_AGENT" == "$EXPECTED_UA" ]]; then
        pass "HEALTH_CHECK_USER_AGENT is '$EXPECTED_UA'"
    else
        fail "HEALTH_CHECK_USER_AGENT value" \
             "expected '$EXPECTED_UA', got '$HEALTH_CHECK_USER_AGENT'"
    fi
else
    fail "HEALTH_CHECK_USER_AGENT is defined" "variable is unset or empty"
fi

# ─── 2. Every health-check curl invocation carries the User-Agent ─────────────
#
# curl and ping are stubbed so all branches can be driven without network
# access. Both the primary paths and the HTTP fallbacks are exercised.

CURL_LOG="$WORKDIR/curl-args.log"
: > "$CURL_LOG"

# Scenario A: every request succeeds, exercising the primary paths.
curl() {
    printf '%s\n' "$*" >> "$CURL_LOG"
    case " $* " in
        *" -w "*) printf '200 0.100' ;;
    esac
    return 0
}

ping() { return 0; }

check_domain_online "example.test" 3 1 1 >/dev/null 2>&1
check_ip_online "203.0.113.10" 1 1 >/dev/null 2>&1
check_ip_http "203.0.113.10" "example.test" 3 1 1 >/dev/null 2>&1

# Scenario B: HTTPS fails, forcing the plain-HTTP fallbacks.
curl() {
    printf '%s\n' "$*" >> "$CURL_LOG"
    case " $* " in
        *" https://"*)
            case " $* " in
                *" -w "*) printf '000 0.000' ;;
            esac
            return 1
            ;;
        *)
            case " $* " in
                *" -w "*) printf '200 0.100' ;;
            esac
            return 0
            ;;
    esac
}

check_ip_online "203.0.113.10" 1 1 >/dev/null 2>&1
check_ip_http "203.0.113.10" "example.test" 3 1 1 >/dev/null 2>&1

unset -f curl ping

INVOCATIONS=$(wc -l < "$CURL_LOG" | tr -d ' ')
MISSING=$(grep -c -v -F -- "$EXPECTED_UA" "$CURL_LOG" || true)

if [[ "$INVOCATIONS" -lt 5 ]]; then
    fail "health-check curl calls are exercised" \
         "expected at least 5 invocations, captured $INVOCATIONS"
elif [[ "$MISSING" -eq 0 ]]; then
    pass "all $INVOCATIONS health-check curl invocations send the User-Agent"
else
    fail "all health-check curl invocations send the User-Agent" \
         "$MISSING of $INVOCATIONS invocations lack '$EXPECTED_UA'"
fi

# ─── 3. The header actually reaches the server ───────────────────────────────
#
# Argument inspection alone cannot prove curl puts the header on the wire, so
# check_domain_online is pointed at a local HTTPS listener that records what it
# received. Skipped rather than silently passed when python3 is unavailable.

if ! command -v python3 >/dev/null 2>&1; then
    skip "User-Agent reaches the server" "python3 not available"
elif ! command -v openssl >/dev/null 2>&1; then
    skip "User-Agent reaches the server" "openssl not available"
else
    PORT=18443
    HEADERS_FILE="$WORKDIR/headers.txt"

    openssl req -x509 -newkey rsa:2048 \
        -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" \
        -days 1 -nodes -subj "/CN=localhost" \
        -addext "subjectAltName=DNS:localhost" >/dev/null 2>&1

    cat > "$WORKDIR/listener.py" <<'PYTHON'
import http.server
import ssl
import sys

workdir, port = sys.argv[1], int(sys.argv[2])


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(workdir + "/headers.txt", "a") as fh:
            fh.write(str(self.headers))
        body = b"ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(workdir + "/cert.pem", workdir + "/key.pem")
server = http.server.HTTPServer(("127.0.0.1", port), Handler)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PYTHON

    python3 "$WORKDIR/listener.py" "$WORKDIR" "$PORT" >/dev/null 2>&1 &
    SRV_PID=$!

    # Wait for the listener to accept connections.
    for _ in $(seq 1 25); do
        if curl -s -o /dev/null -k --max-time 1 "https://localhost:$PORT/" 2>/dev/null; then
            break
        fi
        sleep 0.2
    done

    if ! kill -0 "$SRV_PID" 2>/dev/null; then
        skip "User-Agent reaches the server" "listener failed to start"
    else
        : > "$HEADERS_FILE"
        # Trust the throwaway certificate. It must be exported: curl runs as a
        # child process, so a prefix assignment on the function call would not
        # reach it.
        export CURL_CA_BUNDLE="$WORKDIR/cert.pem"
        check_domain_online "localhost:$PORT" 5 1 1 >/dev/null 2>&1
        unset CURL_CA_BUNDLE

        if [[ ! -s "$HEADERS_FILE" ]]; then
            fail "User-Agent reaches the server" "no request recorded by the listener"
        elif grep -q -F -- "User-Agent: $EXPECTED_UA" "$HEADERS_FILE"; then
            pass "listener received 'User-Agent: $EXPECTED_UA'"
        else
            fail "User-Agent reaches the server" \
                 "listener saw: $(grep -i '^user-agent:' "$HEADERS_FILE" | tr -d '\r')"
        fi
    fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

printf '\n%d run, %d failed, %d skipped\n' "$TESTS_RUN" "$TESTS_FAILED" "$TESTS_SKIPPED"
[[ "$TESTS_FAILED" -eq 0 ]]
