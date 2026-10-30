#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$ROOT/vendor" "$ROOT/deps"
if [[ ! -d "$ROOT/vendor/UxPlay" ]]; then
    git clone https://github.com/FDH2/UxPlay.git "$ROOT/vendor/UxPlay"
    git -C "$ROOT/vendor/UxPlay" checkout 82ad05c
fi
# 82ad05c'de client_time_received hiç true olmuyor: her zaman damgası 0 geliyor, senkron hiç çalışmıyordu.
f="$ROOT/vendor/UxPlay/lib/raop_ntp.c"
grep -q 'client_time_received = true' "$f" ||
    sed -i 's/^\( *\)raop_ntp->sync_offset = sync_offset;$/&\n\1raop_ntp->client_time_received = true;/' "$f"
[[ -f "$ROOT/deps/lib/libcrypto.a" ]] || bash "$ROOT/build-openssl.sh"
[[ -f "$ROOT/deps/lib/libplist-2.0.a" ]] || bash "$ROOT/build-libplist.sh"
