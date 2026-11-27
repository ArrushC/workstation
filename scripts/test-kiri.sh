#!/usr/bin/env bash
# test-kiri.sh: dotfiles/local/bin/kiri-docker and tasks/kiri, against a stand-in for
# Kiri's Windows docker.exe (KIRI_DOCKER) in a scratch HOME. Never the real ~/.local/bin,
# the real state file or a real engine. PATH is a folder of links to the few tools the two
# scripts use, so a dockerd on this host (a CI runner has one) isn't seen unless a case
# puts one there.
#   kiri-docker: the `kiri` context unless one is set, the Compose variables added to
#     WSLENV in front of what it held, arguments passed whole, --where (and --where passed
#     through when called as docker), the cached path used and a stale one refused, 127
#     with no CLI.
#   tasks/kiri: links docker -> kiri-docker, says so on the next run, and leaves docker
#     alone when Kiri isn't installed, a dockerd is on PATH, something else is at
#     ~/.local/bin/docker or the wrapper isn't deployed; exit 0 every time. Off WSL
#     (checked where this host isn't WSL) it does nothing.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrapper_src="$root/dotfiles/local/bin/kiri-docker"
task="$root/tasks/kiri"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() {
  printf '  FAIL  %s\n' "$1" >&2
  fails=$((fails + 1))
}
check() { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }

tools="$tmp/tools"
mkdir -p "$tools"
for t in bash sh env readlink dirname grep ln cat tr mkdir mv rm printf; do
  p="$(command -v "$t")" && [ -x "$p" ] && ln -s "$p" "$tools/$t"
done

# The stand-in CLI: prints its context, WSLENV and arguments, one per line.
fake="$tmp/win/docker.exe"
mkdir -p "$tmp/win"
cat >"$fake" <<'SH'
#!/bin/sh
echo "ctx=$DOCKER_CONTEXT"
echo "wslenv=$WSLENV"
for a in "$@"; do echo "arg=$a"; done
SH
chmod 755 "$fake"

home="$tmp/home"
bin="$home/.local/bin"
fresh_home() {
  rm -rf "$home"
  mkdir -p "$bin"
  cp "$wrapper_src" "$bin/kiri-docker"
}
# run <command...>: in the scratch home, on the tools-only PATH, as a WSL distro.
run() {
  env -i HOME="$home" PATH="$tools" WSL_DISTRO_NAME=Test XDG_STATE_HOME="$home/state" \
    KIRI_DOCKER="${KIRI_DOCKER-$fake}" ${EXTRA_PATH:+PATH="$EXTRA_PATH:$tools"} "${ENVV[@]}" "$@"
}
ENVV=()

echo "kiri-docker"
fresh_home
out="$(run "$bin/kiri-docker" compose -f 'a b.yaml' up)"
check "the kiri context by default" grep -qx 'ctx=kiri' <<<"$out"
check "the Compose variables in WSLENV" grep -qx 'wslenv=DOCKER_CONTEXT:COMPOSE_PROJECT_NAME:COMPOSE_PROFILES:COMPOSE_FILE/l' <<<"$out"
check "arguments passed whole" grep -qx 'arg=a b.yaml' <<<"$out"
ENVV=(DOCKER_CONTEXT=other WSLENV=MY_VAR)
out="$(run "$bin/kiri-docker" ps)"
ENVV=()
check "a set context is kept" grep -qx 'ctx=other' <<<"$out"
check "WSLENV keeps what it held" grep -qx 'wslenv=DOCKER_CONTEXT:COMPOSE_PROJECT_NAME:COMPOSE_PROFILES:COMPOSE_FILE/l:MY_VAR' <<<"$out"
check "--where prints the CLI" [ "$(run "$bin/kiri-docker" --where)" = "$fake" ]
ln -s kiri-docker "$bin/docker"
check "--where is docker's own argument under the docker name" grep -qx 'arg=--where' <<<"$(run "$bin/docker" --where)"
if KIRI_DOCKER="$tmp/none.exe" run "$bin/kiri-docker" ps >/dev/null 2>"$tmp/err"; then rc=0; else rc=$?; fi
check "no CLI: exit 127 and a reason" [ "$rc" = 127 ]
check "no CLI: the reason names Kiri" grep -q "Kiri's CLI" "$tmp/err"
# The cached path (KIRI_DOCKER unset: the lookup itself is cmd.exe's, not run here).
mkdir -p "$home/state/workstation"
echo "$fake" >"$home/state/workstation/kiri-docker"
check "the cached path is used" [ "$(KIRI_DOCKER='' run "$bin/kiri-docker" --where)" = "$fake" ]

echo "tasks/kiri"
fresh_home
out="$(run "$task" 2>&1)"
check "links docker to kiri-docker" [ "$(readlink "$bin/docker")" = kiri-docker ]
check "says so" grep -q "linked $bin/docker -> kiri-docker" <<<"$out"
check "docker then reaches the CLI" grep -qx 'arg=ps' <<<"$(run "$bin/docker" ps)"
check "a second run changes nothing" grep -q "docker is Kiri's CLI" <<<"$(run "$task" 2>&1)"

fresh_home
out="$(KIRI_DOCKER="$tmp/none.exe" run "$task" 2>&1)" && rc=0 || rc=$?
check "Kiri not installed: exit 0, no link" [ "$rc" = 0 ] && check "Kiri not installed: says what to do" grep -q 'not installed on Windows yet' <<<"$out"
check "Kiri not installed: nothing at docker" [ ! -e "$bin/docker" ]

fresh_home
mkdir -p "$tmp/engine"
printf '#!/bin/sh\n' >"$tmp/engine/dockerd"
chmod 755 "$tmp/engine/dockerd"
out="$(EXTRA_PATH="$tmp/engine" run "$task" 2>&1)" && rc=0 || rc=$?
check "a Docker Engine here: exit 0" [ "$rc" = 0 ]
check "a Docker Engine here: docker not linked" [ ! -e "$bin/docker" ]
check "a Docker Engine here: says why" grep -q 'a Docker Engine is installed in this distro' <<<"$out"

fresh_home
echo mine >"$bin/docker"
out="$(run "$task" 2>&1)" && rc=0 || rc=$?
check "something else at docker: left alone" [ "$rc" = 0 ] && check "something else at docker: content kept" [ "$(cat "$bin/docker")" = mine ]
check "something else at docker: says so" grep -q "isn't the link to kiri-docker" <<<"$out"

fresh_home
rm "$bin/kiri-docker"
out="$(run "$task" 2>&1)" && rc=0 || rc=$?
check "wrapper not deployed: exit 0 and a reason" [ "$rc" = 0 ] && check "wrapper not deployed: says ws apply" grep -q 'ws apply deploys it' <<<"$out"

if ! grep -qi microsoft /proc/version 2>/dev/null; then
  fresh_home
  out="$(env -i HOME="$home" PATH="$tools" KIRI_DOCKER="$fake" "$task" 2>&1)" && rc=0 || rc=$?
  check "not WSL: exit 0, silent" [ "$rc" = 0 ] && check "not WSL: nothing printed" [ -z "$out" ]
  check "not WSL: no link" [ ! -e "$bin/docker" ]
else
  echo "  note  this host is WSL: the not-WSL case runs in CI"
fi

if [ "$fails" -gt 0 ]; then
  echo "test-kiri: $fails failed" >&2
  exit 1
fi
echo "test-kiri: all passed"
