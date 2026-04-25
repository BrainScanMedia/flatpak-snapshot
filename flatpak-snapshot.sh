#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║         flatpak-snapshot.sh - BrainScanMedia                    ║
# ║  Scans installed Flatpaks + GNOME layout and generates a        ║
# ║  fully self-contained flatpak-restore.sh for new machines.      ║
# ╚══════════════════════════════════════════════════════════════════╝
# Usage: chmod +x flatpak-snapshot.sh && ./flatpak-snapshot.sh
# Run this anytime on your current machine to regenerate the restore script.

set -e

# ── Colors ──────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="$SCRIPT_DIR/flatpak-restore.sh"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME=$(hostname)

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║              Flatpak Snapshot - Generating Restore Script        ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── 1. Collect installed Flatpak App IDs ────────────────────────────
echo -e "${YELLOW}▸ Scanning installed Flatpak apps...${NC}"
FLATPAK_APPS=$(flatpak list --app --columns=application | tail -n +1 | grep -v '^Application ID$' | sort)
APP_COUNT=$(echo "$FLATPAK_APPS" | grep -c '.')
echo -e "${GREEN}  ✔ Found $APP_COUNT apps${NC}"

# ── 2. Dump GNOME app folder config ─────────────────────────────────
echo -e "${YELLOW}▸ Dumping GNOME app folders (dconf)...${NC}"
GNOME_FOLDERS=$(dconf dump /org/gnome/desktop/app-folders/ 2>/dev/null || echo "")
if [ -n "$GNOME_FOLDERS" ]; then
    echo -e "${GREEN}  ✔ App folders captured${NC}"
else
    echo -e "${YELLOW}  ⚠ No GNOME app folder config found (skipping)${NC}"
fi

# ── 3. Dump GNOME shell config (grid order) ──────────────────────────
echo -e "${YELLOW}▸ Dumping GNOME shell layout (dconf)...${NC}"
GNOME_SHELL=$(dconf dump /org/gnome/shell/ 2>/dev/null || echo "")
if [ -n "$GNOME_SHELL" ]; then
    echo -e "${GREEN}  ✔ Shell layout captured${NC}"
else
    echo -e "${YELLOW}  ⚠ No GNOME shell config found (skipping)${NC}"
fi

# ── 4. Write the restore script ──────────────────────────────────────
echo -e "${YELLOW}▸ Writing restore script to: $OUTPUT${NC}"

cat > "$OUTPUT" << 'SCRIPT_HEADER'
#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║              flatpak-restore.sh - BrainScanMedia                 ║
# ║   AUTO-GENERATED — do not edit by hand.                         ║
# ║   Re-generate with: ./flatpak-snapshot.sh                       ║
# ╚══════════════════════════════════════════════════════════════════╝
# Usage: chmod +x flatpak-restore.sh && ./flatpak-restore.sh

SCRIPT_HEADER

# Inject metadata
cat >> "$OUTPUT" << SCRIPT_META
# Snapshot taken: $TIMESTAMP
# Source machine: $HOSTNAME
# Total apps:     $APP_COUNT

SCRIPT_META

# Inject color/counter setup
cat >> "$OUTPUT" << 'SCRIPT_VARS'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALLED=0
SKIPPED=0
FAILED=0

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║               Flatpak Restore - Starting Install                 ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Add Flathub ───────────────────────────────────────────────────────
echo -e "${YELLOW}▸ Adding Flathub remote (if not already added)...${NC}"
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
echo ""

SCRIPT_VARS

# Inject app list
echo "" >> "$OUTPUT"
echo "# ── App List ─────────────────────────────────────────────────────────" >> "$OUTPUT"
echo "APPS=(" >> "$OUTPUT"
while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    echo "    $app" >> "$OUTPUT"
done <<< "$FLATPAK_APPS"
echo ")" >> "$OUTPUT"
echo "" >> "$OUTPUT"

# Inject install loop
cat >> "$OUTPUT" << 'SCRIPT_LOOP'
# ── Install Loop (with deduplication) ─────────────────────────────────
declare -A SEEN
UNIQUE_APPS=()
for APP in "${APPS[@]}"; do
    [[ -z "$APP" || "$APP" == \#* ]] && continue
    if [[ -z "${SEEN[$APP]}" ]]; then
        SEEN[$APP]=1
        UNIQUE_APPS+=("$APP")
    fi
done

echo -e "${CYAN}▸ Installing ${#UNIQUE_APPS[@]} apps...${NC}"
echo ""

for APP in "${UNIQUE_APPS[@]}"; do
    if flatpak info "$APP" &>/dev/null; then
        echo -e "  ${YELLOW}⊘ Already installed:${NC} $APP"
        ((SKIPPED++))
    else
        echo -e "  ${GREEN}↓ Installing:${NC} $APP"
        if flatpak install -y flathub "$APP" 2>/dev/null; then
            echo -e "  ${GREEN}✔ Done:${NC} $APP"
            ((INSTALLED++))
        else
            echo -e "  ${RED}✘ FAILED:${NC} $APP"
            ((FAILED++))
        fi
    fi
done

echo ""

# ── Flatpak Overrides (sandbox fixes) ─────────────────────────────────
echo -e "${CYAN}▸ Applying Flatpak overrides...${NC}"
echo ""

_override() {
    local app="$1"; shift
    if flatpak info "$app" &>/dev/null; then
        echo -e "  ${GREEN}▸ $app:${NC} $*"
        flatpak override --user "$app" "$@"
    fi
}

_override com.google.Chrome  --filesystem=/run/media --filesystem=/media
_override com.brave.Browser   --filesystem=/run/media --filesystem=/media
_override org.mozilla.firefox --filesystem=/run/media --filesystem=/media
_override org.gnome.NautilusPreviewer --filesystem=/run/media

echo ""

SCRIPT_LOOP

# ── Inject GNOME folders dconf block ────────────────────────────────
cat >> "$OUTPUT" << 'GNOME_HEADER'
# ── Restore GNOME App Folders ──────────────────────────────────────────
echo -e "${CYAN}▸ Restoring GNOME app folders...${NC}"

GNOME_FOLDERS_DATA=$(cat << 'DCONF_FOLDERS_EOF'
GNOME_HEADER

# Write the actual dconf data
printf '%s\n' "$GNOME_FOLDERS" >> "$OUTPUT"
echo "DCONF_FOLDERS_EOF" >> "$OUTPUT"
echo ")" >> "$OUTPUT"
echo "" >> "$OUTPUT"

cat >> "$OUTPUT" << 'GNOME_FOLDERS_APPLY'
if [ -n "$GNOME_FOLDERS_DATA" ]; then
    echo "$GNOME_FOLDERS_DATA" | dconf load /org/gnome/desktop/app-folders/
    echo -e "  ${GREEN}✔ App folders restored${NC}"
else
    echo -e "  ${YELLOW}⚠ No folder data to restore${NC}"
fi
echo ""
GNOME_FOLDERS_APPLY

# ── Inject GNOME shell dconf block ──────────────────────────────────
cat >> "$OUTPUT" << 'SHELL_HEADER'
# ── Restore GNOME Shell Layout ─────────────────────────────────────────
echo -e "${CYAN}▸ Restoring GNOME shell layout...${NC}"

GNOME_SHELL_DATA=$(cat << 'DCONF_SHELL_EOF'
SHELL_HEADER

printf '%s\n' "$GNOME_SHELL" >> "$OUTPUT"
echo "DCONF_SHELL_EOF" >> "$OUTPUT"
echo ")" >> "$OUTPUT"
echo "" >> "$OUTPUT"

cat >> "$OUTPUT" << 'GNOME_SHELL_APPLY'
if [ -n "$GNOME_SHELL_DATA" ]; then
    echo "$GNOME_SHELL_DATA" | dconf load /org/gnome/shell/
    echo -e "  ${GREEN}✔ Shell layout restored${NC}"
else
    echo -e "  ${YELLOW}⚠ No shell layout data to restore${NC}"
fi

echo ""
echo -e "${YELLOW}▸ Restarting GNOME Shell to apply layout...${NC}"
sleep 1
killall -3 gnome-shell 2>/dev/null || true
echo -e "${GREEN}  ✔ Shell restarted${NC}"
echo ""
GNOME_SHELL_APPLY

# ── Inject summary block ─────────────────────────────────────────────
cat >> "$OUTPUT" << 'SCRIPT_FOOTER'
# ── Summary ───────────────────────────────────────────────────────────
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                          Summary                                 ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${GREEN}✔ Installed:${NC}  $INSTALLED"
echo -e "  ${YELLOW}⊘ Skipped:${NC}   $SKIPPED  (already present)"
echo -e "  ${RED}✘ Failed:${NC}    $FAILED"
echo ""

if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED}  Some apps failed. App IDs may have changed on Flathub.${NC}"
    echo -e "  Search manually: flatpak search <appname>"
fi

echo ""
echo -e "${GREEN}  Restore complete! App folders and grid layout applied.${NC}"
echo ""
read -rp "$(echo -e "${CYAN}  Press any key to close...${NC}")" -n1
echo ""
SCRIPT_FOOTER

# ── Make it executable ───────────────────────────────────────────────
chmod +x "$OUTPUT"

echo ""
echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                     Snapshot Complete!                           ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${GREEN}✔ Restore script written to:${NC} $OUTPUT"
echo -e "  ${GREEN}✔ Apps captured:${NC}            $APP_COUNT"
echo -e "  ${GREEN}✔ GNOME folders:${NC}            $([ -n "$GNOME_FOLDERS" ] && echo 'Yes' || echo 'Not found')"
echo -e "  ${GREEN}✔ GNOME shell layout:${NC}       $([ -n "$GNOME_SHELL" ] && echo 'Yes' || echo 'Not found')"
echo ""
echo -e "  ${YELLOW}To use on a new machine:${NC}"
echo -e "  1. Copy ${CYAN}~/flatpak-restore.sh${NC} to the new machine"
echo -e "  2. Run: ${CYAN}chmod +x flatpak-restore.sh && ./flatpak-restore.sh${NC}"
echo ""
read -rp "$(echo -e "${CYAN}  Press any key to close...${NC}")" -n1
echo ""
