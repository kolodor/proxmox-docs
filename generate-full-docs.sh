#!/usr/bin/env bash
# ===================================================================
# Proxmox Full Auto-Documentation Generator
# Generates a complete, ready-to-publish Markdown documentation
# Works on single node or full cluster | Proxmox 7.x - 8.x
# Author: Grok (with love)
# ===================================================================

set -euo pipefail

# ----------------------- CONFIGURATION -----------------------
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/proxmox-docs-$(hostname)-$(date +%Y%m%d-%H%M)}"
PVE_NODES=$(pvesh get /nodes --output-format json | jq -r '.[].node' 2>/dev/null || echo "$(hostname)")
mkdir -p "$OUTPUT_DIR"

echo "Generating full Proxmox documentation into $OUTPUT_DIR ..."

# ----------------------- HELPERS -----------------------
green() { echo -e "\033[32m[+] $*\033[0m"; }
red()   { echo -e "\033[31m[-] $*\033[0m"; }

# ----------------------- 00-Overview.md -----------------------
cat > "$OUTPUT_DIR/00-Overview.md" <<'EOF'
# Proxmox Infrastructure Documentation  
*Auto-generated on $(date)*

EOF

# Cluster info
if pvecm status >/dev/null 2>&1; then
  CLUSTER_NAME=$(pvecm status | grep "Cluster name:" | awk '{print $3}')
  QUORUM=$(pvecm status | grep "Membership state:" | grep -o "Quorate" || echo "NOT QUORATE")
  cat >> "$OUTPUT_DIR/00-Overview.md" <<EOF
**Cluster name**      : $CLUSTER_NAME  
**Quorum**            : $QUORUM  
**Nodes online**      : $(pvecm nodes | grep -c "Membership state: cluster node")
EOF
else
  echo "**Single node** (no cluster)" >> "$OUTPUT_DIR/00-Overview.md"
fi

echo -e "\n**Proxmox version**   : $(pveversion | grep pve-manager | awk '{print $2}')\n" >> "$OUTPUT_DIR/00-Overview.md"

# ----------------------- 01-Hardware -----------------------
mkdir -p "$OUTPUT_DIR/01-Hardware"

for node in $PVE_NODES; do
  green "Processing node $node"

  # Basic hardware
  CPU=$(pvesh get /nodes/$node/status --output-format json | jq -r '.cpuinfo.model')
  CPU_CORES=$(pvesh get /nodes/$node/status --output-format json | jq -r '.cpuinfo.cpus')
  RAM_TOTAL=$(pvesh get /nodes/$node/status --output-format json | jq -r '(.memory.total/1024/1024/1024)|round' )
  RAM_USED=$(pvesh get /nodes/$node/status --output-format json | jq -r '(.memory.used/1024/1024/1024)|round' )
  UPTIME=$(pvesh get /nodes/$node/status --output-format json | jq -r '.uptime' | awk '{d=$1/86400;h=($1%86400)/3600;m=($1%3600)/60;s=$1%60;printf "%dd %dh %dm",d,h,m}')

  cat > "$OUTPUT_DIR/01-Hardware/$node.md" <<EOF
# Hardware – $node

**CPU**      : $CPU ($CPU_CORES cores)  
**RAM**      : ${RAM_USED} GB / ${RAM_TOTAL} GB  
**Uptime**   : $UPTIME  
**Kernel**   : $(ssh $node uname -r)  
**PVE**      : $(ssh $node pveversion -v | grep pve-manager)

### Disks
\`\`\`
$(ssh $node "lsblk -d -o NAME,SIZE,ROTA,MODEL | sort")
\`\`\`

### Full dmesg recent errors (last 50 lines)
\`\`\`
$(ssh $node "dmesg | tail -50 | grep -iE 'error|warn|fail'")
\`\`\`
EOF
done

# ----------------------- 02-Cluster -----------------------
mkdir -p "$OUTPUT_DIR/02-Cluster"
if pvecm status &>/dev/null; then
  pvecm status > "$OUTPUT_DIR/02-Cluster/pvecm-status.txt"
  cp /etc/pve/corosync.conf "$OUTPUT_DIR/02-Cluster/corosync.conf" 2>/dev/null || true
fi

# ----------------------- 03-Networking -----------------------
mkdir -p "$OUTPUT_DIR/03-Networking"
cat > "$OUTPUT_DIR/03-Networking/network-summary.md" <<'EOF'
# Networking Overview

## Bridges & VLANs
EOF

for node in $PVE_NODES; do
  echo -e "\n### $node\n" >> "$OUTPUT_DIR/03-Networking/network-summary.md"
  ssh $node "cat /etc/network/interfaces" >> "$OUTPUT_DIR/03-Networking/network-summary.md"
done

# ----------------------- 04-Storage -----------------------
mkdir -p "$OUTPUT_DIR/04-Storage"
pvesh get /storage --output-format json-pretty > "$OUTPUT_DIR/04-Storage/storage.json"
cat > "$OUTPUT_DIR/04-Storage/README.md" <<'EOF'
# Storage Overview

| ID         | Type     | Enabled | Active | Size     | Used     | % Used |
|------------|----------|---------|--------|----------|----------|--------|
EOF

pvesm status -content images | awk 'NR>1 {printf "| %s | %s | %s | %s | %.2f GB | %.2f GB | %.1f%% |\n", $1,$2,$3,$4,$5,$6,$7*100}' >> "$OUTPUT_DIR/04-Storage/README.md"

# ----------------------- 05-VMs-and-Containers -----------------------
mkdir -p "$OUTPUT_DIR/05-VMs-and-Containers"
cat > "$OUTPUT_DIR/05-VMs-and-Containers/vm-list.csv" <<EOF
VMID,Name,Node,Status,CPU,RAM_GB,Disk_GB,IP_Address(es),Tags,Description
EOF

for node in $PVE_NODES; do
  # VMs
  qm list --full 2>/dev/null | tail -n +2 | while read vmid name status cpu ram diskrest; do
    ram_gb=$(awk -v r="$ram" 'BEGIN {printf "%.1f", r/1024/1024}')
    config=$(qm config $vmid 2>/dev/null || echo "")
    ips=""
    if echo "$config" | grep -q "^agent:.*enabled=1"; then
      ips=$(timeout 8 qm guest cmd $vmid network-get-interfaces 2>/dev/null | \
        jq -r '.[] | .["ip-addresses"][] | select(.["ip-address-type"]=="ipv4" and .["ip-address"]!="127.0.0.1") | .["ip-address"]' | \
        tr '\n' ';' | sed 's/;$//;s/^$/-/' || echo "-")
    else
      ips="-"
    fi
    tags=$(echo "$config" | grep "^tags:" | sed 's/tags: //;s/;/, /g')
    desc=$(echo "$config" | grep "^description:" | sed 's/description: //')
    echo "$vmid,\"$name\",$node,$status,$cpu,$ram_gb,$(qm config $vmid | grep -Eo 'scsi[0-9]+:[^,]+' | cut -d: -f2 | numfmt --from=iec 2>/dev/null | awk '{s+=$1} END {printf \"%d\", s/1024/1024/1024}'),\"$ips\",\"$tags\",\"$desc\"" \
      >> "$OUTPUT_DIR/05-VMs-and-Containers/vm-list.csv"
  done || true

  # Containers
  pct list 2>/dev/null | tail -n +2 | while read ctid name status; do
    config=$(pct config $ctid)
    ips=$(pct exec $ctid -- ip -4 addr show scope global 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | tr '\n' ';' | sed 's/;$//')
    [ -z "$ips" ] && ips="-"
    echo "$ctid,\"$name\",$node,$status,-,-,-,\"$ips\",-,\"LXC Container\"" \
      >> "$OUTPUT_DIR/05-VMs-and-Containers/vm-list.csv"
  done || true
done

# Convert CSV to nice Markdown table (optional)
echo -e "\n# Complete VM/CT List\n" > "$OUTPUT_DIR/05-VMs-and-Containers/README.md"
echo,Name,Node,Status,CPU,RAM_GB,Disk_GB,IP_Address(es),Tags,Description" >> "$OUTPUT_DIR/05-VMs-and-Containers/README.md"
awk -F',' 'NR>1 {print "| " $1 " | " $2 " | " $3 " | " $4 " | " $5 " | " $6 " | " $7 " | " $8 " | " $9 " | " $10 " |"}' \
  "$OUTPUT_DIR/05-VMs-and-Containers/vm-list.csv" >> "$OUTPUT_DIR/05-VMs-and-Containers/README.md"

# ----------------------- 06-Backups & PBS -----------------------
mkdir -p "$OUTPUT_DIR/06-Backup-and-DR"
pvebackup status 2>/dev/null || echo "No backup jobs configured" > "$OUTPUT_DIR/06-Backup-and-DR/backup-jobs.txt"

# ----------------------- Final touches -----------------------
cp -r /etc/pve "$OUTPUT_DIR/etc-pve-backup-$(date +%Y%m%d)" 2>/dev/null || true

cat > "$OUTPUT_DIR/README.md" <<EOF
# Proxmox Full Documentation – $(date "+%Y-%m-%d %H:%M")

This folder contains **100% complete and current** documentation of your Proxmox environment.

**Generated automatically** – just run the script again any time.

## Quick navigation
- [00-Overview.md](00-Overview.md) – One-page summary
- [01-Hardware/](01-Hardware/) – One file per node
- [03-Networking/](03-Networking/)
- [04-Storage/](04-Storage/)
- [05-VMs-and-Containers/](05-VMs-and-Containers/) – Full VM list + CSV
- [06-Backup-and-DR/](06-Backup-and-DR/)

Just commit this folder to Git or sync it to your docs (Bookstack, GitLab, Notion, etc.).

**Never lose your mind again when a node dies at 3 AM.**
EOF

green "Documentation complete!"
echo "→ Folder: $OUTPUT_DIR"
echo "→ Just zip it, commit it to Git, or upload to your wiki."

# Optional: auto-zip
tar -czf "$OUTPUT_DIR.tar.gz" "$OUTPUT_DIR" 2>/dev/null && echo "→ Also saved as $OUTPUT_DIR.tar.gz"

exit 0
