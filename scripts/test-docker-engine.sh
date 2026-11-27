#!/usr/bin/env bash
# test-docker-engine.sh: tasks/docker-engine against fakes (sudo, rpm, systemctl, getent,
# id, curl, gpg) and fixtures (os-release, an /etc tree, a stub bootstrap-fn.sh). sudo
# only logs its arguments: nothing is installed, no service is touched, no real /etc.
#   - WSL, sudo = "no", a release that isn't RHEL-family and podman-docker: nothing runs;
#   - everything present: one line, no sudo, no download;
#   - a fresh host: the key is checked, then key, repo file, dnf install, enable --now and
#     gpasswd run in that order, with exactly those arguments;
#   - a key with another fingerprint, or two keys in the file: nothing is written or installed;
#   - a failed download: nothing installed;
#   - the repo file and key already in place: no download, straight to dnf;
#   - packages there but the service off or the user not in the group: only that step;
#   exit 0 every time.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task="$root/tasks/docker-engine"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() {
  printf '  FAIL  %s\n' "$1" >&2
  fails=$((fails + 1))
}
check() { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }

pin=060A61C51B558A7F742B77AAC52FEB6B621E9F35
fake="$tmp/fake"
mkdir -p "$fake"
log="$tmp/log"
mk() {
  cat >"$fake/$1"
  chmod 755 "$fake/$1"
}
mk sudo <<'SH'
#!/bin/sh
echo "sudo $*" >>"$FAKE_LOG"
[ "${FAKE_SUDO_FAIL:-}" = "$1" ] && exit 1
exit 0
SH
mk rpm <<'SH'
#!/bin/sh
# rpm -q <name> [...]: present when the name is in FAKE_RPM_HAS.
for a in "$@"; do last="$a"; done
case " ${FAKE_RPM_HAS:-} " in *" $last "*) [ "$1 $2" = "-q --qf" ] && printf 29.10.1; exit 0 ;; esac
exit 1
SH
mk systemctl <<'SH'
#!/bin/sh
[ "${FAKE_RUNNING:-0}" = 1 ]
SH
mk getent <<'SH'
#!/bin/sh
echo "docker:x:990:${FAKE_GROUP_MEMBERS:-}"
SH
mk id <<'SH'
#!/bin/sh
echo me
SH
mk curl <<'SH'
#!/bin/sh
echo "curl $*" >>"$FAKE_LOG"
[ "${FAKE_CURL_FAIL:-0}" = 1 ] && exit 22
while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done
echo key >"$out"
SH
mk gpg <<'SH'
#!/bin/sh
printf '%s' "$FAKE_GPG" | tr '|' '\n'
SH
stub="$tmp/bootstrap-fn"
cat >"$stub" <<'SH'
#!/bin/sh
case "$1" in
is_wsl) [ "${FAKE_WSL:-0}" = 1 ] ;;
config_get) echo "${FAKE_SUDO:-}" ;;
esac
SH
chmod 755 "$stub"
printf 'ID="almalinux"\nID_LIKE="rhel centos fedora"\nVERSION_ID="9.6"\n' >"$tmp/os-alma9"
printf 'ID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"\n' >"$tmp/os-ubuntu"
one_key="pub:-:4096:1:C52FEB6B621E9F35:1487791233:::-:::escaESCA:|fpr:::::::::$pin:|uid:-::::1::X::Docker Release:|sub:-:4096:1:AAAA:1:|fpr:::::::::1111111111111111111111111111111111111111:|"
all="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

# run [VAR=value...]: the task on the fakes, a fresh /etc fixture unless KEEP_ETC=1.
run() {
  [ "${KEEP_ETC:-0}" = 1 ] || rm -rf "${tmp:?}/etc"
  : >"$log"
  out="$(env PATH="$fake:$PATH" FAKE_LOG="$log" WORKSTATION_BOOTSTRAP_FN="$stub" WORKSTATION_ETC="$tmp/etc" \
    WORKSTATION_OS_RELEASE="$tmp/os-alma9" FAKE_GPG="$one_key" "$@" bash "$task" 2>&1)" && rc=0 || rc=$?
}
quiet() { [ "$rc" = 0 ] && [ ! -s "$log" ]; }

run FAKE_WSL=1
check "WSL: exit 0, nothing run, nothing said" quiet && check "WSL: silent" [ -z "$out" ]
run FAKE_SUDO=no
check 'sudo = "no": nothing run' quiet && check 'sudo = "no": says so' grep -q 'sudo = "no"' <<<"$out"
run WORKSTATION_OS_RELEASE="$tmp/os-ubuntu"
check "not RHEL-family: nothing run" quiet && check "not RHEL-family: says so" grep -q 'not a RHEL-family release (ubuntu)' <<<"$out"
run FAKE_RPM_HAS=podman-docker
check "podman-docker: left alone" quiet && check "podman-docker: says so" grep -q 'podman-docker answers to docker' <<<"$out"

run FAKE_RPM_HAS="$all" FAKE_RUNNING=1 FAKE_GROUP_MEMBERS=you,me
check "all present: no sudo, no download" quiet
check "all present: one line with the version" grep -qx '  docker-engine: Docker Engine 29.10.1 is installed and running; me is in the docker group' <<<"$out"

run
check "fresh host: exit 0" [ "$rc" = 0 ]
want="$(
  cat <<EOT
curl -fsSL --proto =https --tlsv1.2 --retry 3 --max-time 60 -o KEY https://download.docker.com/linux/rhel/gpg
sudo install -D -m 644 KEY $tmp/etc/pki/rpm-gpg/RPM-GPG-KEY-docker-ce
sudo install -D -m 644 $root/configs/docker/docker-ce.repo $tmp/etc/yum.repos.d/docker-ce.repo
sudo dnf install -y $all
sudo systemctl enable --now docker.service
sudo gpasswd -a me docker
EOT
)"
got="$(sed -E 's#[^ ]*/tmp\.[A-Za-z0-9]+/key#KEY#' "$log")"
check "fresh host: key, repo, dnf, service, group, in that order" [ "$got" = "$want" ]
[ "$got" = "$want" ] || printf '%s\n' "--- got" "$got" "--- want" "$want" >&2
check "fresh host: tells you to log in again" grep -q 'added me to the docker group: log out and in' <<<"$out"

run FAKE_GPG="${one_key//$pin/0000000000000000000000000000000000000000}"
check "another key: nothing written or installed" [ "$rc" = 0 ] && check "another key: no sudo" [ "$(grep -c '^sudo' "$log")" = 0 ]
check "another key: says so" grep -q "isn't Docker's pinned release key" <<<"$out"
run FAKE_GPG="$one_key$one_key"
check "two keys in the file: refused" [ "$(grep -c '^sudo' "$log")" = 0 ]
run FAKE_CURL_FAIL=1
check "download failed: no sudo" [ "$(grep -c '^sudo' "$log")" = 0 ] && check "download failed: says the next run retries" grep -q 'the next run retries' <<<"$out"

rm -rf "${tmp:?}/etc"
mkdir -p "$tmp/etc/yum.repos.d" "$tmp/etc/pki/rpm-gpg"
cp "$root/configs/docker/docker-ce.repo" "$tmp/etc/yum.repos.d/"
echo key >"$tmp/etc/pki/rpm-gpg/RPM-GPG-KEY-docker-ce"
KEEP_ETC=1 run
check "repo and key in place: no download" [ "$(grep -c '^curl' "$log")" = 0 ]
check "repo and key in place: straight to dnf" [ "$(head -1 "$log")" = "sudo dnf install -y $all" ]

run FAKE_RPM_HAS="$all" FAKE_GROUP_MEMBERS=me
check "service off: only enable --now" [ "$(cat "$log")" = 'sudo systemctl enable --now docker.service' ]
run FAKE_RPM_HAS="$all" FAKE_RUNNING=1
check "not in the group: only gpasswd" [ "$(cat "$log")" = 'sudo gpasswd -a me docker' ]
run FAKE_SUDO_FAIL=dnf
check "dnf fails: exit 0, no service or group step" [ "$rc" = 0 ] && check "dnf fails: stops there" [ "$(tail -1 "$log")" = "sudo dnf install -y $all" ]
check "dnf fails: says the bootstrap continues" grep -q 'the bootstrap continues' <<<"$out"

if [ "$fails" -gt 0 ]; then
  echo "test-docker-engine: $fails failed" >&2
  exit 1
fi
echo "test-docker-engine: all passed"
