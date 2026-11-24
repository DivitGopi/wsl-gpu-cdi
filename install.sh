#!/bin/sh
# Install or remove wsl-gpu.
#   doas ./install.sh                 install the command and the boot service
#   doas ./install.sh --with-gcompat  also install gcompat (nvidia-smi on the host)
#   doas ./install.sh --uninstall     remove everything
# SPDX-License-Identifier: MIT
set -eu

PREFIX="${PREFIX:-/usr/local}"
BINDIR="$PREFIX/bin"
SRC="$(cd "$(dirname "$0")" && pwd)"

die() { printf 'install: error: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "run as root (doas ./install.sh or sudo ./install.sh)"

with_gcompat=0
action=install
for a in "$@"; do
	case "$a" in
		--with-gcompat) with_gcompat=1 ;;
		--uninstall) action=uninstall ;;
		-h | --help)
			sed -n '2,6p' "$0"
			exit 0
			;;
		*) die "unknown option: $a" ;;
	esac
done

has_openrc() { command -v rc-update >/dev/null 2>&1 && [ -d /etc/init.d ]; }
has_systemd() { [ -d /run/systemd/system ]; }

install_file() { # src dest mode
	mkdir -p "$(dirname "$2")"
	sed "s|@BINDIR@|$BINDIR|g" "$1" >"$2.new"
	chmod "$3" "$2.new"
	mv -f "$2.new" "$2"
}

if [ "$action" = uninstall ]; then
	if has_openrc && [ -e /etc/init.d/wsl-gpu-cdi ]; then
		rc-update del wsl-gpu-cdi default >/dev/null 2>&1 || true
		rm -f /etc/init.d/wsl-gpu-cdi
	fi
	if has_systemd && [ -e /etc/systemd/system/wsl-gpu-cdi.service ]; then
		systemctl disable wsl-gpu-cdi.service >/dev/null 2>&1 || true
		rm -f /etc/systemd/system/wsl-gpu-cdi.service
		systemctl daemon-reload
	fi
	[ -x "$BINDIR/wsl-gpu" ] && "$BINDIR/wsl-gpu" remove || true
	rm -f "$BINDIR/wsl-gpu"
	say "wsl-gpu removed."
	exit 0
fi

install_file "$SRC/bin/wsl-gpu" "$BINDIR/wsl-gpu" 0755
say "installed $BINDIR/wsl-gpu"

if has_openrc; then
	install_file "$SRC/init/openrc/wsl-gpu-cdi" /etc/init.d/wsl-gpu-cdi 0755
	rc-update add wsl-gpu-cdi default >/dev/null
	say "installed OpenRC service wsl-gpu-cdi (runlevel: default)"
elif has_systemd; then
	install_file "$SRC/init/systemd/wsl-gpu-cdi.service" /etc/systemd/system/wsl-gpu-cdi.service 0644
	systemctl daemon-reload
	systemctl enable wsl-gpu-cdi.service >/dev/null 2>&1
	say "installed systemd unit wsl-gpu-cdi.service"
else
	say "no OpenRC or systemd found: run \`wsl-gpu generate\` after each boot yourself"
fi

if [ "$with_gcompat" -eq 1 ]; then
	if command -v apk >/dev/null 2>&1; then
		apk add --no-cache gcompat >/dev/null
		say "installed gcompat"
	else
		say "--with-gcompat only applies to Alpine; skipped"
	fi
fi

"$BINDIR/wsl-gpu" generate --if-present
say
say "Check the setup with:  wsl-gpu doctor --run-test"
