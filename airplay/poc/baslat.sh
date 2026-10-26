#!/bin/sh
launchctl remove tr.niladsp.aracekran 2>/dev/null
killall aracekran 2>/dev/null
trap "" HUP
/var/mobile/aracekran "$@" </dev/null >/dev/null 2>&1 &
sleep 3
ps ax | grep aracekra[n]
