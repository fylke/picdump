# shellcheck shell=bash

Describe 'picdump.sh'
  Include ./picdump.sh

  setup() {
    TMP=$(mktemp -d)
    LOG_FILE="$TMP/log"
    : > "$LOG_FILE"
    PATH="$PWD/spec/support:$PATH"
    FAKE_EXIF_TABLE="$TMP/table"
    export FAKE_EXIF_TABLE
  }
  cleanup() {
    rm -rf -- "$TMP"
  }
  BeforeEach setup
  AfterEach cleanup

  Describe 'parse_args'
    It 'applies long options'
      When call parse_args --mode both --source /s --remote-base h:/p --ssh-port 22 --label x --retries 5 --retry-delay 1 --dry-run
      The variable MODE should eq both
      The variable SOURCE_DIR should eq /s
      The variable REMOTE_BASE should eq h:/p
      The variable SSH_PORT should eq 22
      The variable LABEL should eq x
      The variable MAX_ATTEMPTS should eq 5
      The variable RETRY_DELAY should eq 1
      The variable DRY_RUN should eq true
    End

    It 'supports -n and -b aliases'
      When call parse_args -n
      The variable MODE should eq nas
    End

    It 'rejects unknown options'
      When run parse_args --bogus
      The status should be failure
      The stderr should include 'Unknown option'
    End

    It 'rejects a missing option value'
      When run parse_args --source
      The status should be failure
      The stderr should include 'Missing value'
    End

    It 'prints usage for --help'
      When run parse_args --help
      The status should be success
      The output should include 'Usage: picdump.sh'
    End
  End

  Describe 'validate_settings'
    valid() { MODE=both; SOURCE_DIR=/s; REMOTE_BASE=h:/p; }

    It 'accepts valid settings'
      valid
      When call validate_settings
      The status should be success
    End

    It 'rejects an invalid mode'
      valid; MODE=bogus
      When run validate_settings
      The stderr should include 'Mode must be'
      The status should be failure
    End

    It 'rejects a non-numeric retry count'
      valid; MAX_ATTEMPTS=abc
      When run validate_settings
      The stderr should include 'Retries'
      The status should be failure
    End

    It 'rejects an out-of-range ssh port'
      valid; SSH_PORT=70000
      When run validate_settings
      The stderr should include 'SSH port'
      The status should be failure
    End

    It 'rejects labels with path characters'
      valid; LABEL='../escape'
      When run validate_settings
      The stderr should include 'Label'
      The status should be failure
    End

    It 'requires a source'
      valid; SOURCE_DIR=''
      When run validate_settings
      The stderr should include '--source'
      The status should be failure
    End

    It 'requires a remote for nas and both'
      valid; REMOTE_BASE=''
      When run validate_settings
      The stderr should include '--remote-base'
      The status should be failure
    End

    It 'does not require a remote in local mode'
      valid; MODE=local; REMOTE_BASE=''
      When call validate_settings
      The status should be success
    End
  End

  Describe 'resolve_date'
    It 'uses the EXIF date of the first media file'
      mkdir -p "$TMP/src"; : > "$TMP/src/a.jpg"
      SOURCE_DIR="$TMP/src"
      FAKE_EXIF_DATE='2024:02:29' export FAKE_EXIF_DATE
      When call resolve_date
      The variable YEAR should eq 2024
      The variable MONTH should eq 02
      The variable DAY should eq 29
    End

    It 'falls back to today without media files'
      mkdir -p "$TMP/src"
      SOURCE_DIR="$TMP/src"
      When call resolve_date
      The variable YEAR should eq "$(date +%Y)"
    End

    It 'ignores malformed dates'
      mkdir -p "$TMP/src"; : > "$TMP/src/a.jpg"
      SOURCE_DIR="$TMP/src"
      FAKE_EXIF_DATE='garbage' export FAKE_EXIF_DATE
      When call resolve_date
      The variable YEAR should eq "$(date +%Y)"
    End
  End

  Describe 'make_targets'
    It 'builds a dated folder name'
      YEAR=2026 MONTH=11 DAY=03 LABEL='' LOCAL_BASE=/l/ REMOTE_BASE=h:/r/
      When call make_targets
      The variable LOCAL_TARGET should eq '/l/2026-11_-_03'
      The variable NAS_TARGET should eq 'h:/r/2026-11_-_03'
    End

    It 'includes the label'
      YEAR=2026 MONTH=11 DAY=03 LABEL=trip LOCAL_BASE=/l REMOTE_BASE=h:/r
      When call make_targets
      The variable LOCAL_TARGET should eq '/l/2026-11_-_trip_-_03'
    End
  End

  Describe 'build_rename_plan'
    plan() {
      build_rename_plan >/dev/null
      ls "$STAGE_DIR" | LC_ALL=C sort
      rm -rf -- "$STAGE_DIR"
    }
    row() { printf '%s\t%s\t%s\t%s\t%s\n' "$@" >> "$TMP/table"; }

    It 'renames by capture time with lowercase extensions'
      SOURCE_DIR="$TMP/src"
      row /c/100 IMG_1.JPG 20261030_120000 - -
      When call plan
      The output should include '20261030_120000.jpg'
      The stderr should be blank
    End

    It 'gives RAW+JPG pairs the same name'
      SOURCE_DIR="$TMP/src"
      row /c/100 IMG_2.JPG 20261030_120509 - -
      row /c/100 IMG_2.CR3 - - 20261101_000000
      When call plan
      The line 1 of output should eq '20261030_120509.cr3'
      The line 2 of output should eq '20261030_120509.jpg'
    End

    It 'suffixes different shots with the same timestamp'
      SOURCE_DIR="$TMP/src"
      row /c/100 IMG_1.JPG 20261030_120000 - -
      row /c/101 IMG_1.JPG 20261030_120000 - -
      When call plan
      The line 1 of output should eq '20261030_120000.jpg'
      The line 2 of output should eq '20261030_120000_1.jpg'
    End

    It 'falls back to modification time'
      SOURCE_DIR="$TMP/src"
      row /c/100 NOTE.TXT - - 20260101_010203
      When call plan
      The output should eq '20260101_010203.txt'
    End

    It 'is deterministic regardless of input order'
      SOURCE_DIR="$TMP/src"
      row /c/101 IMG_1.JPG 20261030_120000 - -
      row /c/100 IMG_1.JPG 20261030_120000 - -
      When call plan
      The line 2 of output should eq '20261030_120000_1.jpg'
    End

    It 'skips files with no date'
      SOURCE_DIR="$TMP/src"
      row /c/100 X.BIN - - -
      When call plan
      The output should eq ''
      The contents of file "$LOG_FILE" should include 'No date found'
    End
  End

  Describe 'sync functions'
    rsync() { printf '%s\n' "$*" >> "$TMP/rsync_calls"; return "${RSYNC_STATUS:-0}"; }
    sleep() { :; }

    It 'passes --dry-run and --copy-links to local rsync'
      STAGE_DIR=/stage SOURCE_DIR=/s LOCAL_TARGET=/l DRY_RUN=true
      When call sync_source_to_local
      The status should be success
      The output should include 'Local sync completed'
      The contents of file "$TMP/rsync_calls" should include '--dry-run'
      The contents of file "$TMP/rsync_calls" should include '--copy-links'
    End

    It 'reports local rsync failure'
      STAGE_DIR=/stage SOURCE_DIR=/s LOCAL_TARGET=/l DRY_RUN=false RSYNC_STATUS=23
      When call sync_source_to_local
      The status should eq 23
      The output should include 'exit status 23'
    End

    It 'uses the ssh port for remote rsync'
      STAGE_DIR=/stage SOURCE_DIR=/s NAS_TARGET=h:/r DRY_RUN=false SSH_PORT=4545 MAX_ATTEMPTS=1 RETRY_DELAY=0
      When call sync_source_to_remote
      The output should include 'Remote sync completed'
      The contents of file "$TMP/rsync_calls" should include 'ssh -p 4545'
    End

    It 'retries then fails after the maximum attempts'
      STAGE_DIR=/stage SOURCE_DIR=/s NAS_TARGET=h:/r DRY_RUN=false SSH_PORT='' MAX_ATTEMPTS=3 RETRY_DELAY=0 RSYNC_STATUS=1
      When call sync_source_to_remote
      The status should be failure
      The output should include 'failed after 3 attempts'
      The lines of contents of file "$TMP/rsync_calls" should eq 3
    End
  End
End
