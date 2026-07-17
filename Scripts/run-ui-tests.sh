#!/usr/bin/env bash
set -euo pipefail

if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fi
configuration="$repo_root/.vm-uitest.conf"

if [[ ! -f "$configuration" ]]; then
    echo "error: missing $configuration" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$configuration"
: "${PROJECT_DIR:?missing PROJECT_DIR in .vm-uitest.conf}"
: "${XCODE_PROJECT:?missing XCODE_PROJECT in .vm-uitest.conf}"
: "${SCHEME:?missing SCHEME in .vm-uitest.conf}"

golden_vm="${GOLDEN_VM:-goldengate-xcode-golden}"
guest_user="${GUEST_USER:-xctester}"
guest_directory="${GUEST_DIR:-localmcp-uitest}"
vm_key="${VM_KEY:-${HOME}/.ssh/localmcp_vm}"
vm_name="localmcp-uitest-$$"
results_directory="$repo_root/test-results"
ssh_options=(
    -i "$vm_key"
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=5
    -o LogLevel=ERROR
)

for dependency in tart ssh rsync scp; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        echo "error: required command is unavailable: $dependency" >&2
        exit 1
    fi
done

if [[ ! -f "$vm_key" ]]; then
    echo "error: VM SSH key not found: $vm_key" >&2
    echo "Set VM_KEY to the private key authorized by the golden image." >&2
    exit 1
fi

if ! tart list --quiet 2>/dev/null | grep -Fqx "$golden_vm"; then
    echo "error: Tart golden image not found: $golden_vm" >&2
    echo "Set GOLDEN_VM to a macOS image with Xcode and Remote Login configured." >&2
    exit 1
fi

# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
    tart stop "$vm_name" >/dev/null 2>&1 || true
    tart delete "$vm_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ -n "${PREPARE_CMD:-}" ]]; then
    echo "==> Preparing project on host ($PREPARE_CMD)"
    (cd "$repo_root/$PROJECT_DIR" && /bin/zsh -lc "$PREPARE_CMD" >/dev/null)
fi

echo "==> Cloning $golden_vm → $vm_name"
tart clone "$golden_vm" "$vm_name"
tart run "$vm_name" --no-graphics >/dev/null 2>&1 &

echo "==> Waiting for VM to boot"
vm_ip=""
for _ in {1..90}; do
    if vm_ip="$(tart ip "$vm_name" 2>/dev/null)" && [[ -n "$vm_ip" ]]; then
        break
    fi
    sleep 2
done
if [[ -z "$vm_ip" ]]; then
    echo "error: VM never received an IP address" >&2
    exit 1
fi

for _ in {1..60}; do
    if ssh -n "${ssh_options[@]}" "$guest_user@$vm_ip" true 2>/dev/null; then
        break
    fi
    sleep 2
done
if ! ssh -n "${ssh_options[@]}" "$guest_user@$vm_ip" true 2>/dev/null; then
    echo "error: SSH never became available at $vm_ip" >&2
    exit 1
fi
echo "    VM up at $vm_ip"

echo "==> Syncing sources to guest"
rsync -a --delete -e "ssh ${ssh_options[*]}" \
    --exclude '.build/' \
    --exclude 'build/' \
    --exclude '.git/' \
    --exclude 'test-results/' \
    --exclude '*.xcresult' \
    "$repo_root/$PROJECT_DIR/" "$guest_user@$vm_ip:$guest_directory/"

echo "==> Running UI tests in guest ($SCHEME)"
set +e
ssh -n "${ssh_options[@]}" "$guest_user@$vm_ip" \
    "set -o pipefail; cd '$guest_directory' && rm -rf /tmp/localmcp-uitest.xcresult && xcodebuild \
        -project '$XCODE_PROJECT' \
        -scheme '$SCHEME' \
        -derivedDataPath build \
        -resultBundlePath /tmp/localmcp-uitest.xcresult \
        test 2>&1 | tail -40"
status=$?
set -e

echo "==> Fetching result bundle"
mkdir -p "$results_directory"
timestamp="$(date +%Y%m%d-%H%M%S)"
result_path="$results_directory/uitest-$timestamp.xcresult"
if scp -r -q "${ssh_options[@]}" \
    "$guest_user@$vm_ip:/tmp/localmcp-uitest.xcresult" "$result_path" 2>/dev/null; then
    echo "    $result_path"
fi

if [[ "$status" -eq 0 ]]; then
    echo "==> UI tests PASSED"
else
    echo "==> UI tests FAILED (xcodebuild exit $status)"
fi
exit "$status"
