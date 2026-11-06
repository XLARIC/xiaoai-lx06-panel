#!/bin/sh
set -eu
ubus -t 3 call service add '{"name":"lx06_panel","instances":{"web":{"command":["/data/lx06-panel/launch.sh"],"respawn":[3600,5,5],"term_timeout":2}}}'
