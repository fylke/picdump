#!/usr/bin/env bash

set -Eeuo pipefail

MODE="${PICDUMP_MODE:-local}"
SOURCE_DIR="${PICDUMP_SOURCE:-}"
LOCAL_BASE="${PICDUMP_LOCAL_BASE:-${HOME}/Pictures/Unprocessed}"
REMOTE_BASE="${PICDUMP_REMOTE_BASE:-}"
WINDOWS_DRIVE="${PICDUMP_WINDOWS_DRIVE:-}"
SSH_PORT="${PICDUMP_SSH_PORT:-}"
LOG_FILE="${PICDUMP_LOG_FILE:-${HOME}/.local/state/picdump/picdump.log}"
LABEL="${PICDUMP_LABEL:-}"
DRY_RUN="${PICDUMP_DRY_RUN:-false}"
MAX_ATTEMPTS="${PICDUMP_RETRIES:-3}"
RETRY_DELAY="${PICDUMP_RETRY_DELAY:-30}"
MOUNTED_BY_SCRIPT=false
STAGE_DIR=""

usage() {
    cat <<'EOF'
Usage: picdump.sh [options]

Copy a camera card to a local folder, a remote rsync destination, or both.

Options:
  -m, --mode MODE          local (default), nas, or both
  -s, --source PATH        Source directory (the card; required in all modes)
  -l, --local-base PATH    Local archive base (default: ~/Pictures/Unprocessed)
  -r, --remote-base DEST   Remote rsync destination, e.g. user@host:/path
  -p, --ssh-port PORT      SSH port for remote transfers
  -d, --label LABEL        Optional label added to the dated folder name
      --retries COUNT      Maximum remote attempts (default: 3)
      --retry-delay SEC    Seconds between remote attempts (default: 30)
  -D, --dry-run            Show what would be transferred without copying
  -n                       Alias for --mode nas
  -b                       Alias for --mode both
  -h, --help               Show this help

Settings can also be supplied through PICDUMP_* environment variables.
EOF
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

parse_args() {
    while (($#)); do
        case "$1" in
            -m|--mode)
                (($# >= 2)) || fail "Missing value for $1"
                MODE="$2"
                shift 2
                ;;
            -s|--source)
                (($# >= 2)) || fail "Missing value for $1"
                SOURCE_DIR="$2"
                shift 2
                ;;
            -l|--local-base)
                (($# >= 2)) || fail "Missing value for $1"
                LOCAL_BASE="$2"
                shift 2
                ;;
            -r|--remote-base)
                (($# >= 2)) || fail "Missing value for $1"
                REMOTE_BASE="$2"
                shift 2
                ;;
            -p|--ssh-port)
                (($# >= 2)) || fail "Missing value for $1"
                SSH_PORT="$2"
                shift 2
                ;;
            -d|--label)
                (($# >= 2)) || fail "Missing value for $1"
                LABEL="$2"
                shift 2
                ;;
            --retries)
                (($# >= 2)) || fail "Missing value for $1"
                MAX_ATTEMPTS="$2"
                shift 2
                ;;
            --retry-delay)
                (($# >= 2)) || fail "Missing value for $1"
                RETRY_DELAY="$2"
                shift 2
                ;;
            -D|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -n)
                MODE="nas"
                shift
                ;;
            -b)
                MODE="both"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                (($# == 0)) || fail "Unexpected positional arguments"
                ;;
            -*)
                fail "Unknown option: $1 (use --help for usage)"
                ;;
            *)
                fail "Unexpected argument: $1 (use --help for usage)"
                ;;
        esac
    done
}

cleanup() {
    local exit_status=$?
    trap - EXIT
    [[ -z "$STAGE_DIR" ]] || rm -rf -- "$STAGE_DIR"
    if [[ "$MOUNTED_BY_SCRIPT" == true ]]; then
        log "Unmounting source drive..."
        if ! sudo umount "$SOURCE_DIR"; then
            log "ERROR: Failed to unmount $SOURCE_DIR"
            ((exit_status != 0)) || exit_status=1
        fi
    fi
    exit "$exit_status"
}

validate_settings() {
    case "$MODE" in
        local|nas|both) ;;
        *) fail "Mode must be local, nas, or both" ;;
    esac

    [[ "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] ||
        fail "Retries must be a positive integer"
    [[ "$RETRY_DELAY" =~ ^[0-9]+$ ]] ||
        fail "Retry delay must be a non-negative integer"
    if [[ -n "$SSH_PORT" ]]; then
        [[ "$SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] &&
            ((SSH_PORT <= 65535)) ||
            fail "SSH port must be between 1 and 65535"
    fi
    if [[ -n "$LABEL" ]]; then
        [[ "$LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9._\ -]*$ ]] ||
            fail "Label may contain only letters, numbers, spaces, dots, underscores, and hyphens"
    fi
    if [[ -z "$SOURCE_DIR" && -z "$WINDOWS_DRIVE" ]]; then
        fail "Set --source or PICDUMP_WINDOWS_DRIVE"
    fi
    if [[ "$MODE" != local && -z "$REMOTE_BASE" ]]; then
        fail "Set --remote-base or PICDUMP_REMOTE_BASE for nas/both mode"
    fi
}

configure_source() {
    command -v rsync >/dev/null 2>&1 || fail "rsync is required"
    command -v exiftool >/dev/null 2>&1 || fail "exiftool is required"

    if [[ -n "$WINDOWS_DRIVE" ]]; then
        [[ "$WINDOWS_DRIVE" =~ ^[A-Za-z]$ ]] ||
            fail "PICDUMP_WINDOWS_DRIVE must be a single drive letter"
        [[ -n "$SOURCE_DIR" ]] || SOURCE_DIR="/mnt/${WINDOWS_DRIVE,,}"
    fi

    command -v find >/dev/null 2>&1 || fail "find is required"
    if [[ -n "$WINDOWS_DRIVE" ]]; then
        command -v mountpoint >/dev/null 2>&1 || fail "mountpoint is required for WSL drive mounting"
    fi

    if [[ -n "$WINDOWS_DRIVE" ]] && ! mountpoint -q "$SOURCE_DIR"; then
        command -v sudo >/dev/null 2>&1 || fail "sudo is required to mount the Windows drive"
        mkdir -p "$SOURCE_DIR"
        if find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
            fail "Refusing to mount over non-empty directory: $SOURCE_DIR"
        fi
        log "Mounting Windows drive ${WINDOWS_DRIVE^^}: at $SOURCE_DIR..."
        if sudo mount -t drvfs "${WINDOWS_DRIVE^^}:" "$SOURCE_DIR" \
            -o "uid=$(id -u),gid=$(id -g)"; then
            MOUNTED_BY_SCRIPT=true
        else
            fail "Could not mount Windows drive ${WINDOWS_DRIVE^^}:"
        fi
    fi

    [[ -d "$SOURCE_DIR" ]] || fail "Source directory does not exist: $SOURCE_DIR"
    SOURCE_DIR=$(cd "$SOURCE_DIR" && pwd)
}

resolve_date() {
    YEAR=$(date +%Y)
    MONTH=$(date +%m)
    DAY=$(date +%d)

    local first_file exif_dates candidate
    first_file=$(find "$SOURCE_DIR" -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.cr3' \
            -o -iname '*.nef' -o -iname '*.arw' -o -iname '*.mp4' \
            -o -iname '*.mov' \) -print -quit)
    [[ -n "$first_file" ]] || return 0
    if exif_dates=$(exiftool -s3 -d '%Y:%m:%d' \
        -DateTimeOriginal -CreateDate -- "$first_file" 2>>"$LOG_FILE"); then
        while IFS= read -r candidate; do
            if [[ "$candidate" =~ ^([0-9]{4}):([0-9]{2}):([0-9]{2})$ ]]; then
                YEAR="${BASH_REMATCH[1]}"
                MONTH="${BASH_REMATCH[2]}"
                DAY="${BASH_REMATCH[3]}"
                break
            fi
        done <<< "$exif_dates"
    else
        log "WARNING: exiftool could not read a capture date; using today's date."
    fi
}

make_targets() {
    local folder_name="${YEAR}-${MONTH}_-_${DAY}"
    if [[ -n "$LABEL" ]]; then
        folder_name="${YEAR}-${MONTH}_-_${LABEL}_-_${DAY}"
    fi

    LOCAL_TARGET="${LOCAL_BASE%/}/${folder_name}"
    NAS_TARGET="${REMOTE_BASE%/}/${folder_name}"
}

# Rsync cannot rename, so stage symlinks named by capture time and copy
# them with --copy-links. Names are deterministic, so reruns stay idempotent.
build_rename_plan() {
    STAGE_DIR=$(mktemp -d)
    local -A stem_stamp=() stem_index=() stamp_count=()
    local -a files=() exif_stamps=() mtime_stamps=()
    local src dir d1 d2 d3 stem stamp idx name base ext i count=0

    while IFS=$'\t' read -r dir base d1 d2 d3; do
        files+=("$dir/$base")
        exif_stamps+=("$d1"$'\t'"$d2")
        mtime_stamps+=("$d3")
    done < <(exiftool -r -m -q -T -d '%Y%m%d_%H%M%S' \
                -Directory -FileName -DateTimeOriginal -CreateDate -FileModifyDate \
                -- "$SOURCE_DIR" 2>>"$LOG_FILE" | LC_ALL=C sort -t $'\t' -k1,2)

    # Files sharing a source stem (e.g. RAW+JPG) share one timestamp:
    # the first capture time found, else the first modification time.
    for i in "${!files[@]}"; do
        stem="${files[i]%.*}"
        [[ -z "${stem_stamp[$stem]+x}" ]] || continue
        for stamp in ${exif_stamps[i]//$'\t'/ }; do
            if [[ "$stamp" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
                stem_stamp[$stem]="$stamp"
                break
            fi
        done
    done
    for i in "${!files[@]}"; do
        stem="${files[i]%.*}"
        [[ -z "${stem_stamp[$stem]+x}" ]] || continue
        if [[ "${mtime_stamps[i]}" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
            stem_stamp[$stem]="${mtime_stamps[i]}"
        fi
    done

    for i in "${!files[@]}"; do
        src="${files[i]}"
        stem="${src%.*}"
        if [[ -z "${stem_stamp[$stem]+x}" ]]; then
            log "WARNING: No date found for $src; skipping."
            continue
        fi
        stamp="${stem_stamp[$stem]}"
        if [[ -z "${stem_index[$stem]+x}" ]]; then
            idx="${stamp_count[$stamp]:-0}"
            stamp_count[$stamp]=$((idx + 1))
            stem_index[$stem]="$idx"
        fi
        idx="${stem_index[$stem]}"

        name="$stamp"
        ((idx == 0)) || name="${name}_${idx}"
        base="${src##*/}"
        if [[ "$base" == *.* && "$base" != .* ]]; then
            ext="${base##*.}"
            name="${name}.${ext,,}"
        fi
        ln -s -- "$src" "$STAGE_DIR/$name"
        count=$((count + 1))
    done

    log "Prepared $count file(s) renamed by capture time."
}

sync_source_to_local() {
    log "Syncing source [$SOURCE_DIR] to local target [$LOCAL_TARGET]..."
    local -a dry_options=()
    [[ "$DRY_RUN" != true ]] || dry_options=(--dry-run)
    if rsync -avh --copy-links "${dry_options[@]}" --mkpath -- "$STAGE_DIR/" "$LOCAL_TARGET/" >>"$LOG_FILE" 2>&1; then
        log "Local sync completed."
    else
        local status=$?
        log "ERROR: Local rsync failed with exit status $status."
        return "$status"
    fi
}

sync_source_to_remote() {
    local -a ssh_options=() dry_options=()
    [[ "$DRY_RUN" != true ]] || dry_options=(--dry-run)
    if [[ -n "$SSH_PORT" ]]; then
        ssh_options=(-e "ssh -p $SSH_PORT")
    fi

    local attempt
    for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
        log "Remote sync attempt $attempt/$MAX_ATTEMPTS: [$SOURCE_DIR] -> [$NAS_TARGET]"
        if rsync -avh --copy-links "${dry_options[@]}" "${ssh_options[@]}" --timeout=60 --mkpath -- \
            "$STAGE_DIR/" "$NAS_TARGET/" >>"$LOG_FILE" 2>&1; then
            log "Remote sync completed."
            return 0
        fi
        if ((attempt < MAX_ATTEMPTS)); then
            log "Remote sync failed; retrying in $RETRY_DELAY seconds."
            sleep "$RETRY_DELAY"
        fi
    done

    log "ERROR: Remote sync failed after $MAX_ATTEMPTS attempts."
    return 1
}

main() {
    parse_args "$@"
    validate_settings

    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    configure_source
    resolve_date
    make_targets
    build_rename_plan

    log "--- Backup started: $(date) ---"
    case "$MODE" in
        local)
            sync_source_to_local
            ;;
        nas)
            sync_source_to_remote
            ;;
        both)
            both_status=0
            sync_source_to_local || both_status=1
            sync_source_to_remote || both_status=1
            ((both_status == 0)) || fail "One or more transfers failed"
            ;;
    esac
    log "Backup finished."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
