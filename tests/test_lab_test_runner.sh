#!/usr/bin/env bash
set -euo pipefail

# Test harness for lab CLI test gate and runner functions

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_BIN="${REPO_ROOT}/bin/lab"

TMP_DIR=$(mktemp -d /tmp/lab-cli-tests-XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_REGISTRY="${TMP_DIR}/services.json"

# Mock service directory
mkdir -p "${TMP_DIR}/mock_service"
mkdir -p "${TMP_DIR}/mock_service/sub_dir"

cat > "${TEST_REGISTRY}" <<EOF
{
  "manifest_service": {
    "compose": "${TMP_DIR}/mock_service/docker-compose.yaml",
    "repo": null,
    "container": "mock-container",
    "health": "echo ok",
    "env_mode": "single",
    "test": {
      "framework": "pytest",
      "suites": [
        {
          "name": "unit",
          "tier": 1,
          "phase": "pre_deploy",
          "required": true,
          "command": "echo 'unit passed'"
        },
        {
          "name": "integration",
          "tier": 2,
          "phase": "pre_deploy",
          "required": true,
          "command": "echo 'integration passed'"
        },
        {
          "name": "failing_suite",
          "tier": 3,
          "phase": "pre_deploy",
          "required": true,
          "command": "false"
        },
        {
          "name": "canary",
          "tier": 5,
          "phase": "post_deploy",
          "required": true,
          "command": "echo 'canary passed'"
        }
      ]
    }
  },
  "passing_service": {
    "compose": "${TMP_DIR}/mock_service/docker-compose.yaml",
    "repo": null,
    "container": "mock-passing",
    "health": "echo ok",
    "env_mode": "single",
    "test": {
      "framework": "pytest",
      "suites": [
        {
          "name": "unit",
          "tier": 1,
          "phase": "pre_deploy",
          "required": true,
          "command": "echo 'unit passed'"
        },
        {
          "name": "canary",
          "tier": 5,
          "phase": "post_deploy",
          "required": true,
          "command": "echo 'canary passed'"
        }
      ]
    }
  },
  "legacy_service": {
    "compose": "${TMP_DIR}/mock_service/docker-compose.yaml",
    "repo": null,
    "container": "mock-legacy",
    "health": "echo ok",
    "env_mode": "single"
  }
}
EOF

export LAB_REGISTRY="${TEST_REGISTRY}"

echo "=== Test 1: lab test runs pre_deploy suites by default ==="
output=$("${LAB_BIN}" test passing_service 2>&1)
echo "$output" | grep -q "unit passed" || { echo "FAILED: unit suite not run"; exit 1; }
echo "$output" | grep -q "canary passed" && { echo "FAILED: canary ran when it should be post_deploy only"; exit 1; }
echo "PASS: lab test pre_deploy default"

echo "=== Test 2: lab test --tier filters correctly ==="
output=$("${LAB_BIN}" test manifest_service --tier 2 2>&1)
echo "$output" | grep -q "integration passed" || { echo "FAILED: tier 2 not run"; exit 1; }
echo "$output" | grep -q "unit passed" && { echo "FAILED: tier 1 ran when tier 2 requested"; exit 1; }
echo "PASS: lab test --tier filter"

echo "=== Test 3: lab test --live runs post_deploy suites ==="
output=$("${LAB_BIN}" test passing_service --live 2>&1)
echo "$output" | grep -q "canary passed" || { echo "FAILED: canary suite not run with --live"; exit 1; }
echo "PASS: lab test --live"

echo "=== Test 4: lab test propagates failure ==="
set +e
"${LAB_BIN}" test manifest_service --tier 3 >/dev/null 2>&1
exit_code=$?
set -e
if [[ $exit_code -eq 0 ]]; then
    echo "FAILED: lab test should have failed on failing suite"
    exit 1
fi
echo "PASS: lab test error propagation"

echo "=== Test 5: legacy service emits warning on lab test ==="
# Mock .venv so it doesn't fail trying to run pytest
mkdir -p "${TMP_DIR}/mock_service/.venv/bin"
cat > "${TMP_DIR}/mock_service/.venv/bin/python" <<'PYEOF'
#!/usr/bin/env bash
exit 0
PYEOF
chmod +x "${TMP_DIR}/mock_service/.venv/bin/python"

output=$("${LAB_BIN}" test legacy_service 2>&1)
echo "$output" | grep -q "legacy service without test manifest" || { echo "FAILED: legacy warning not emitted"; exit 1; }
echo "PASS: legacy service warning"

echo "=== ALL LAB TEST RUNNER TESTS PASSED ==="
