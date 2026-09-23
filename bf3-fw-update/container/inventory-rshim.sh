#!/usr/bin/env bash
set -euo pipefail

sanitize_field() {
    tr '\t\r\n' '   ' <<<"${1:-}" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

interface_for_pf() {
    local pf=$1 net_path device_path
    for net_path in /sys/class/net/*; do
        device_path=$(readlink -f "$net_path/device" 2>/dev/null || true)
        if [[ ${device_path##*/} == "$pf" ]]; then
            basename "$net_path"
            return 0
        fi
    done
    printf '%s\n' '-'
}

printf 'RSHIM\tMGMT_BDF\tPF_BDF\tPSID\tFW\tOPN\tMODE\tIFACE\n'

shopt -s nullglob
for misc in /dev/rshim*/misc; do
    rshim=$(basename "$(dirname "$misc")")
    dev_name=$(sed -n 's/^DEV_NAME[[:space:]]*//p' "$misc" | head -1)
    [[ $dev_name == pcie-* ]] || continue

    mgmt=${dev_name#pcie-}
    pf=${mgmt%.*}.0
    query=$(flint -d "$pf" q 2>/dev/null || true)
    [[ -n $query ]] || continue

    psid=$(sed -n 's/^PSID:[[:space:]]*//p' <<<"$query" | head -1)
    fw=$(sed -n 's/^FW Version:[[:space:]]*//p' <<<"$query" | head -1)
    opn=$(sed -n 's/^Part Number:[[:space:]]*//p' <<<"$query" | head -1)
    if [[ -z $opn ]]; then
        manager=$(mlxfwmanager -d "$pf" --query 2>/dev/null || true)
        opn=$(sed -n 's/^[[:space:]]*Part Number:[[:space:]]*//p' \
            <<<"$manager" | head -1)
    fi
    mode=$(mlxconfig -d "$pf" q INTERNAL_CPU_OFFLOAD_ENGINE 2>/dev/null |
        sed -n 's/.*INTERNAL_CPU_OFFLOAD_ENGINE[[:space:]]*//p' | head -1)
    iface=$(interface_for_pf "$pf")

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(sanitize_field "$rshim")" \
        "$(sanitize_field "$mgmt")" \
        "$(sanitize_field "$pf")" \
        "$(sanitize_field "$psid")" \
        "$(sanitize_field "$fw")" \
        "$(sanitize_field "$opn")" \
        "$(sanitize_field "$mode")" \
        "$(sanitize_field "$iface")"
done | sort -V

