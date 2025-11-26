#!/usr/bin/env bash
# ===================================================================
# Proxmox Full Auto-Documentation Generator – NO jq REQUIRED
# Works on any fresh Proxmox node out of the box
# ===================================================================

set -euo pipefail

# ----------------------- CONFIGURATION -----------------------
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/proxmox-docs-$(hostname)-$(date +%Y%m%d-%H%M)}"
mkdir -p "$OUTPUT_DIR"

echo "Generating full Proxmox documentation into $OUTPUT_DIR ..."

# ----------------------- HELPERS -----------------------
green() { printf "\033[32m[+] %s\033[0m\n" "$*"; }
red()   { printf "\033[31m[-] %s\033[0m\n" "$*"; }

# ----------------------- Get list of nodes without jq -----------------------
if pvesh get /cluster/resources --output-format json >/dev/null 2>&1; then
    PVE_NODES=$(pvesh get /nodes | grep -oE '"node":"[^"]+' | cut -d'"' -f4 | sort -u)
else
    PVE_NODES=$(hostname)
fi
[ -z "$PVE_NODES" ] && PVE_NODES=$(hostname)

# ----------------------- 00-Overview.md -----------------------
cat > "$OUTPUT_DIR/00-Overview.md" <<EOF
# Proxmox Infrastructure Documentation  
*Auto-generated on $(date)*

EOF

# Cluster info
if command -v pvecm >/dev/null && pvecm status >/dev/null 2>&1; then
    CLUSTER_NAME=$(pvecm status | grep "Cluster name:" | awk '{print $3}')
    cat >> "$OUTPUT_DIR/00-Overview.md" <<EOF
**Cluster name**      : $CLUSTER_NAME  
**Quorum**            : $(pvecm status | grep -q Quorate && echo "YES" || echo "NO")  
**Nodes in cluster**  : $(pvecm nodes | grep -c Membership)
EOF
else
    echo "**Single node** (no cluster detected)" >> "$OUTPUT_DIR/00-Overview.md"
fi

echo -e "\n**Proxmox version**   : $(pveversion | grep pve-manager | awk '{print $2}')\n" >> "$OUTPUT_DIR/00-Overview.md"

# ----------------------- 01-Hardware -----------------------
mkdir -p "$OUTPUT_DIR/01-Hardware"

for node in $PVE_NODES; do
    green "Processing node $node ..."

    # Hardware via API (JSON parsing without jq)
    STATUS_JSON=$(pvesh get /nodes/"$node"/status --output-format json)
    CPU_MODEL=$(echo "$STATUS_JSON" | grep -o '"model":"[^"]*' | cut -d'"' -f4 | head -1)
    CPU_CORES=$(echo "$STATUS_JSON" | grep -o '"cpus":[0-9]*' | cut -d: -f2 | head -1)
    RAM_TOTAL_GB=$(echo "$STATUS_JSON" | grep -o '"total":[0-9]*' | head -1 | cut -d: -f2)
    RAM_TOTAL_GB=$((RAM_TOTAL_GB / 1024 / 1024 / 1024))
    RAM_USED_GB=$(echo "$STATUS_JSON" | grep -o '"used":[0-9]*' | head -1 | cut -d: -f2)
    RAM_USED_GB=$((RAM_USED_GB / 1024 / 1024 / 1024))
    UPTIME_SEC=$(echo "$STATUS_JSON" | grep -o '"uptime":[0-9]*' | cut -d: -f2)
    UPTIME_DAYS=$((UPTIME_SEC / 86400))

    cat > "$OUTPUT_DIR/01-Hardware/$node.md" <<EOF
# Hardware – $node

**CPU**       : $CPU_MODEL ($CPU_CORES cores)  
**RAM**       : ${RAM_USED_GB} GB used / ${RAM_TOTAL_GB} GB total  
**Uptime**    : ${UPTIME_DAYS} days  
**Kernel**    : $(ssh -o ConnectTimeout=5 "$node" uname -r 2>/dev/null || echo "n/a")  
**PVE version**: $(ssh -o ConnectTimeout=5 "$node" pveversion | grep pve-manager || echo "n/a")

### Disks (lsblk)
\`\`\`
$(ssh -o ConnectTimeout=10 "$node" "lsblk -d -p -o NAME,SIZE,ROTA,MODEL,VENDOR | sort" 2>/dev/null || echo "ssh failed")
\`\`\`
EOF
done

# ----------------------- 02-Cluster -----------------------
mkdir -p "$OUTPUT_DIR/02-Cluster"
if command -v pvecm >/dev/null && pvecm status >/dev/null 2>&1; then
    pvecm status > "$OUTPUT_DIR/02-Cluster/pvecm-status.txt"
    cp /etc/pve/corosync.conf "$OUTPUT_DIR/02-Cluster/corosync.conf" 2>/dev/null || true
fi

# ----------------------- 03-Networking -----------------------
mkdir -p "$OUTPUT_DIR/03-Networking"
cat > "$OUTPUT_DIR/03-Networking/network-summary.md" <<'EOF'
# Networking Overview

EOF
for node in $PVE_NODES; do
    echo -e "## Node: $node\n\`\`\`" >> "$OUTPUT_DIR/03-Networking/network-summary.md"
    ssh -o ConnectTimeout=10 "$node" "cat /etc/network/interfaces" 2>/dev/null || echo "no access" \
        >> "$OUTPUT_DIR/03-Networking/network-summary.md"
    echo -e "\`\`\`\n" >> "$OUTPUT_DIR/03-Networking/network-summary.md"
done

# ----------------------- 04-Storage -----------------------
mkdir -p "$OUTPUT_DIR/04-Storage"
pvesm status > "$OUTPUT_DIR/04-Storage/pvesm-status.txt"

cat > "$OUTPUT_DIR/04-Storage/README.md" <<'EOF'
# Storage Overview

| Storage | Type   | Active | Total     | Used      | %     |
|---------|--------|--------|-----------|-----------|-------|
EOF
awk 'NR>1 {printf "| %-7s | %-6s | %-6s | %8s GB | %8s GB | %5.1f%%\n", $1, $2, $3, $5, $6, $7*100}' \
    "$OUTPUT_DIR/04-Storage/pvesm-status.txt" >> "$OUTPUT_DIR/04-Storage/README.md"

# ----------------------- 05-VMs-and-Containers -----------------------
mkdir -p "$OUTPUT_DIR/05-VMs-and-Containers"

cat > "$OUTPUT_DIR/05-VMs-and-Containers/vm-list.csv" <<EOF
VMID,Name,Node,Status,CPU,RAM_GB,Disk_GB,IP(s),Tags,Description
EOF

for node in $PVE_NODES; do
    # === VMs ===
    qm list 2>/dev/null | tail -n +2 | awk '{print $1" "$2" "$3" "$4" "$5}' | while read vmid name status cpus ram; do
        ram_gb=$(printf "%.1f" "$(echo "$ram / 1024 / 1024" | bc -l 2>/dev/null || echo 0)")
        config=$(qm config "$vmid" 2>/dev/null || echo "")

        # Disk size (sum of all scsi/virtio/ide/sata lines)
        disk_gb=$(echo "$config" | grep -E '^(scsi|virtio|ide|sata)[0-9]+:' | \
                  grep -o '[0-9.]\+[KMGT]B' | numfmt --from=iec 2>/dev/null | \
                  awk '{s+=$1} END {printf "%.0f", s/1024/1024/1024}')

        # IPs via QEMU guest agent (if enabled)
        ips="-"
        if echo "$config" | grep -q "agent:.*enabled=1"; then
            ips=$(timeout 10 qm guest cmd "$vmid" network-get-interfaces 2>/dev/null | \
                  grep -o '"ip-address":"[0-9.]\+' | cut -d'"' -f4 | grep -v '^127\.' | \
                  tr '\n' ';' | sed 's/;$//')
            [ -z "$ips" ] && ips="-"
        fi

        tags=$(echo "$config" | grep '^tags:' | sed 's/tags: //;s/;/, /g')
        desc=$(echo "$config" | grep '^description:' | sed 's/description: //')

        echo "$vmid,\"$name\",$node,$status,$cpus,$ram_gb,$disk_gb,\"$ips\",\"$tags\",\"$desc\"" \
            >> "$OUTPUT_DIR/05-VMs-and-Containers/vm-list.csv"
    done || true

    # === Containers ===
    pct list 2>/dev/null | tail -n +2 | while read ctid name status; do
        ips=$(pct exec "$ctid" -- ip -4 addr show scope global 2>/dev/null | awk '{print $2}' | cut -d/ -f1 | tr '\n' ';' | sed 's/;$//')
        [ -z "$ips" ] && ips="-"
        echo "$ctid,\"$name\",$node,$status,-,-,-,\"$ips\",-,\"LXC\"" \
            >> "$OUTPUT_DIR/05-VMs-and-Containers/vm-list.csv"
    done || true
done

# ----------------------- Final README -----------------------
cat > "$OUTPUT_DIR/README.md" <<EOF
# Proxmox Full Documentation – $(date "+%Y-%m-%d %H:%M")

100% automatically generated – just re-run the script anytime.

Folder contains:
- Hardware details per node
- Full VM + LXC list (CSV + readable)
- Networking config
- Storage status
- Cluster info (if any)

Ready to commit to Git, import into Bookstack, or just keep as backup.
EOF

green "DONE! Documentation generated in: $OUTPUT_DIR"
echo "   You can now:"
echo "   • tar -czf backup-docs.tar.gz $OUTPUT_DIR"
echo "   • git init $OUTPUT_DIR && cd $OUTPUT_DIR && git add . && git commit -m 'auto-doc $(date)'"

exit 0
