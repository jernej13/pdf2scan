#!/usr/bin/env bash
set -euo pipefail

show_help() {
    cat <<EOF
Usage: $0 [options] input.pdf output.pdf

Options:
  -h, --help              Show this help message
  -d, --dpi DPI           Render DPI (default: 100)
  -g, --gamma GAMMA       Gamma correction (default: 1.5)
  -c, --contrast CONTRAST Brightness-contrast (default: 0x80)
  -t, --threshold THRESH  Convert to 1-bit using threshold (optional, e.g., 50%)
  -q, --quality QUALITY   JPEG quality (1-100, default 60)
  -a, --adaptive          Convert to 1-bit using adaptive thresholding
  -v, --verbose           Show detailed logs
EOF
}

# ----------------------
# Defaults
# ----------------------
dpi=100
gamma=1
contrast="0x50"
threshold=""     # default empty; only triggers 1-bit if explicitly set
quality=60
adaptive=false
verbose=false

# ----------------------
# Parse flags
# ----------------------
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help; exit 0 ;;
        -d|--dpi) dpi="$2"; shift 2 ;;
        -g|--gamma) gamma="$2"; shift 2 ;;
        -c|--contrast) contrast="$2"; shift 2 ;;
        -t|--threshold) threshold="$2"; shift 2 ;;
        -q|--quality) quality="$2"; shift 2 ;;
        -a|--adaptive) adaptive=true; shift ;;
        -v|--verbose) verbose=true; shift ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1"; show_help; exit 1 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
set -- "${POSITIONAL[@]}"

if [ "${#POSITIONAL[@]}" -lt 2 ]; then
    echo "Error: input.pdf and output.pdf required"
    show_help
    exit 1
fi

in="$1"
out="$2"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

pages=$(pdfinfo "$in" | awk '/^Pages:/ {print $2}')

cpu_cores=$(nproc)
total_mem_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
total_mem_mb=$((total_mem_kb / 1024))
mem_per_page=150

max_jobs=$(( total_mem_mb / mem_per_page ))
(( max_jobs > cpu_cores )) && max_jobs=$cpu_cores
(( max_jobs < 1 )) && max_jobs=1

log() {
    if [ "$verbose" = true ]; then
        echo "$@"
    fi
}

# ----------------------
# Render pages to grayscale
# ----------------------
render_page() {
    i="$1"
    img="$tmpdir/$i.jpg"

    log "[RENDER] Page $i: start (PID $$)"
    gs -q -dBATCH -dNOPAUSE \
       -sDEVICE=jpeggray \
       -dJPEGQ="${quality}" \
       -r"${dpi}" \
       -dFirstPage="$i" -dLastPage="$i" \
       -sOutputFile="$img" \
       "$in"
    log "[RENDER] Page $i: done"
}

export -f render_page log
export in tmpdir dpi quality verbose

seq 1 "$pages" | parallel -j "$max_jobs" render_page

# ----------------------
# Process pages: gamma/contrast, optional 1-bit
# ----------------------
process_page() {
    i="$1"
    img="$tmpdir/$i.jpg"
    proc="$tmpdir/${i}_proc.png"

    while true; do
        avail_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
        avail_mb=$((avail_kb / 1024))
        (( avail_mb > mem_per_page * 2 )) && break
        log "[PROCESS] Page $i: waiting for RAM... (${avail_mb}MB free)"
        sleep 1
    done

    log "[PROCESS] Page $i: start (PID $$)"

    args=(-colorspace Gray)

    # Apply gamma/contrast
    [ -n "$gamma" ] && args+=(-gamma "$gamma")
    [ -n "$contrast" ] && args+=(-brightness-contrast "$contrast")

    # Apply 1-bit only if threshold is set or adaptive flag is used
    if [ "$adaptive" = true ]; then
        args+=(-type bilevel)
    elif [ -n "$threshold" ]; then
        args+=(-threshold "$threshold")
    fi

    magick "$img" "${args[@]}" "$proc"

    log "[PROCESS] Page $i: done"
    rm -f "$img"
}

export -f process_page
export mem_per_page adaptive gamma contrast threshold verbose tmpdir

seq 1 "$pages" | parallel -j "$max_jobs" process_page

# ----------------------
# Merge into PDF
# ----------------------
log "[INFO] Merging pages into PDF..."

mapfile -t proc_files < <(find "$tmpdir" -name "*_proc.png" | sort -V)

if [ ${#proc_files[@]} -eq 0 ]; then
    echo "Error: no processed images found"
    exit 1
fi

img2pdf "${proc_files[@]}" -o "$out"

log "[INFO] Finished: $out"

