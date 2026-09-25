#!/usr/bin/env bash
# Back-compat wrapper — prefer yarn measure:route-cost:eth
exec "$(dirname "$0")/measure-route-cost-eth.sh" "$@"
