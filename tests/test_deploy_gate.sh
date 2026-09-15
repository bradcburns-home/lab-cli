#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_BIN="${REPO_ROOT}/bin/lab"

TMP_DIR=$(mktemp -d /tmp/lab-cli-deploy-tests-XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_REGISTRY="${TMP_DIR}/services.json"
mkdir -p "${TMP_DIR}/svc"
mkdir -p "${TMP_DIR}/bin"

# Create a mock docker and docker-compose on PATH
cat > "${TMP_DIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"compose"* && "$*" == *"build"* ]]; then
    echo "MOCK DOCKER BUILD"
    exit 0
elif [[ "$*" == *"compose"* && "$*" == *"up"* ]]; then
    echo "MOCK DOCKER UP"
    exit 0
elif [[ "$*" == *"ps"* ]]; then
    echo "mock-container"
    exit 0
elif [[ "$*" == *"logs"* ]]; then
    echo "clean logs"
    exit 0
fi
exit 0
EOF
chmod +x "${TMP_DIR}/bin/docker"
export PATH="${TMP_DIR}/bin:${PATH}"

touch "${TMP_DIR}/svc/docker-compose.yaml"

cat > "${TEST_REGISTRY}" <<EOF
{
  "failing_pre_deploy": {
    "compose": "${TMP_DIR}/svc/docker-compose.yaml",
    "repo": null,
    "container": "mock-fail-container",
    "health": "echo ok",
    "env_mode": "single",
    "test": {
      "framework": "pytest",
      "suites": [
        {
          "name": "broken_unit",
          "tier": 1,
          "phase": "pre_deploy",
          "required": true,
          "command": "false"
        }
      ]
    }
  },
  "failing_post_deploy": {
    "compose": "${TMP_DIR}/svc/docker-compose.yaml",
    "repo": null,
    "container": "mock-fail-post-container",
    "health": "echo ok",
    "env_mode": "single",
    "test": {
      "framework": "pytest",
      "suites": [
        {
          "name": "good_unit",
          "tier": 1,
          "phase": "pre_deploy",
          "required": true,
          "command": "true"
        },
        {
          "name": "bad_canary",
          "tier": 5,
          "phase": "post_deploy",
          "required": true,
          "command": "false"
        }
      ]
    }
  },
  "passing_deploy": {
    "compose": "${TMP_DIR}/svc/docker-compose.yaml",
    "repo": null,
    "container": "mock-pass-container",
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
          "command": "echo 'pre-deploy passed'"
        },
        {
          "name": "canary",
          "tier": 5,
          "phase": "post_deploy",
          "required": true,
          "command": "echo 'post-deploy canary passed'"
        }
      ]
    }
  },
  "legacy_deploy": {
    "compose": "${TMP_DIR}/svc/docker-compose.yaml",
    "repo": null,
    "container": "mock-legacy-container",
    "health": "echo ok",
    "env_mode": "single"
  }
}
EOF

export LAB_REGISTRY="${TEST_REGISTRY}"

echo "=== Test 1: Pre-deploy test failure blocks deployment before build ==="
set +e
output=$("${LAB_BIN}" deploy failing_pre_deploy 2>&1)
exit_code=$?
set -e
if [[ $exit_code -eq 0 ]]; then
    echo "FAILED: deploy should have failed on broken pre-deploy test"
    exit 1
fi
echo "$output" | grep -q "Pre-deploy test gate FAILED" || { echo "FAILED: expected pre-deploy failure message"; exit 1; }
echo "$output" | grep -q "MOCK DOCKER BUILD" && { echo "FAILED: docker build was called after test failure!"; exit 1; }
echo "PASS: pre-deploy test gate halts deployment before build"

echo "=== Test 2: --skip-test-gate bypasses pre-deploy check ==="
output=$("${LAB_BIN}" deploy failing_pre_deploy --skip-test-gate 2>&1)
echo "$output" | grep -q "SKIPPING pre-deploy test gate" || { echo "FAILED: skip warning not found"; exit 1; }
echo "$output" | grep -q "deployed successfully" || { echo "FAILED: deployment did not succeed with bypass"; exit 1; }
echo "PASS: --skip-test-gate bypass works with warning"

echo "=== Test 3: Passing service runs both pre-deploy and post-deploy gates ==="
output=$("${LAB_BIN}" deploy passing_deploy 2>&1)
echo "$output" | grep -q "Pre-deploy test gate PASSED" || { echo "FAILED: pre-deploy passed message missing"; exit 1; }
echo "$output" | grep -q "Post-deploy acceptance canary PASSED" || { echo "FAILED: post-deploy passed message missing"; exit 1; }
echo "$output" | grep -q "deployed successfully" || { echo "FAILED: deploy did not succeed"; exit 1; }
echo "PASS: passing service completes full deploy gate"

echo "=== Test 4: Post-deploy canary failure halts deployment with error ==="
set +e
output=$("${LAB_BIN}" deploy failing_post_deploy 2>&1)
exit_code=$?
set -e
if [[ $exit_code -eq 0 ]]; then
    echo "FAILED: deploy should have failed on broken post-deploy canary"
    exit 1
fi
echo "$output" | grep -q "Post-deploy canary.*FAILED" || { echo "FAILED: expected post-deploy failure message"; exit 1; }
echo "PASS: post-deploy canary failure returns error"

echo "=== Test 5: Legacy service emits warning on deploy ==="
output=$("${LAB_BIN}" deploy legacy_deploy 2>&1)
echo "$output" | grep -q "legacy service without test manifest" || { echo "FAILED: expected legacy warning"; exit 1; }
echo "PASS: legacy deploy warning emitted"

echo "=== ALL DEPLOY GATE TESTS PASSED ==="
