#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Do not enable shell tracing: this process handles credentials.
set +x
export AWS_EC2_METADATA_DISABLED=true
export AWS_DEFAULT_REGION=us-east-1

LESSON_ID="${LESSON_ID:-}"
JOB_ID="${JOB_ID:-}"
SOURCE_OBJECT_KEY="${SOURCE_OBJECT_KEY:-}"
B2_BUCKET_NAME="${B2_BUCKET_NAME:-}"
B2_ENDPOINT="${B2_ENDPOINT:-}"
B2_SOURCE_KEY_ID="${B2_SOURCE_KEY_ID:-}"
B2_SOURCE_APPLICATION_KEY="${B2_SOURCE_APPLICATION_KEY:-}"
B2_HLS_KEY_ID="${B2_HLS_KEY_ID:-}"
B2_HLS_APPLICATION_KEY="${B2_HLS_APPLICATION_KEY:-}"
SUPABASE_URL="${SUPABASE_URL:-}"
TRANSCODE_CALLBACK_SECRET="${TRANSCODE_CALLBACK_SECRET:-}"

UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
SOURCE_KEY_RE='^courses/videos/[A-Za-z0-9_-]{1,128}/[A-Za-z0-9._-]{1,200}$'

# Validate identifiers and callback configuration before arming the failure callback.
if [[ ! "$LESSON_ID" =~ $UUID_RE || ! "$JOB_ID" =~ $UUID_RE ]]; then
  echo "::error::Invalid lesson or job identifier."
  exit 1
fi
if [[ ! "$SOURCE_OBJECT_KEY" =~ $SOURCE_KEY_RE || "$SOURCE_OBJECT_KEY" == *".."* ]]; then
  echo "::error::Invalid source object key."
  exit 1
fi
if [[ ! "$SUPABASE_URL" =~ ^https://[A-Za-z0-9.-]+\.supabase\.co/?$ || -z "$TRANSCODE_CALLBACK_SECRET" ]]; then
  echo "::error::Callback configuration is missing or invalid."
  exit 1
fi
SUPABASE_URL="${SUPABASE_URL%/}"
CALLBACK_URL="${SUPABASE_URL}/functions/v1/transcode-callback"

OUTPUT_PREFIX="courses/hls/${LESSON_ID}/${JOB_ID}"
WORK_DIR=""
FAILURE_CODE="TRANSCODE_FAILED"
COMPLETION_CALLBACK_ATTEMPTED=0

send_callback() {
  local callback_status="$1"
  local failure_code="${2:-TRANSCODE_FAILED}"
  local manifest_key="${3:-}"
  local body=""
  local http_code=""

  if [[ "$callback_status" == "completed" ]]; then
    body="$(jq -cn \
      --arg lesson_id "$LESSON_ID" \
      --arg job_id "$JOB_ID" \
      --arg output_manifest_key "$manifest_key" \
      '{lesson_id:$lesson_id,job_id:$job_id,status:"completed",output_manifest_key:$output_manifest_key}')" || return 1
  else
    body="$(jq -cn \
      --arg lesson_id "$LESSON_ID" \
      --arg job_id "$JOB_ID" \
      --arg failure_code "$failure_code" \
      '{lesson_id:$lesson_id,job_id:$job_id,status:"failed",failure_code:$failure_code,error_message:"Transcoding reported a failure"}')" || return 1
  fi

  # Response body is discarded so internal details are not leaked into Actions logs.
  if ! http_code="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 10 --max-time 45 \
    --request POST "$CALLBACK_URL" \
    --header 'Content-Type: application/json' \
    --header "x-transcode-callback-secret: ${TRANSCODE_CALLBACK_SECRET}" \
    --data "$body")"; then
    return 1
  fi
  [[ "$http_code" =~ ^2[0-9][0-9]$ ]]
}

on_exit() {
  local exit_code=$?
  trap - EXIT

  if (( exit_code != 0 )) && (( COMPLETION_CALLBACK_ATTEMPTED == 0 )); then
    if send_callback "failed" "$FAILURE_CODE" ""; then
      echo "Transcoding failure status reported to Supabase."
    else
      echo "::warning::Could not report the failed job to Supabase; check the callback function logs."
    fi
  fi

  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
  exit "$exit_code"
}
trap on_exit EXIT

die() {
  FAILURE_CODE="$1"
  echo "::error::Transcoding failed (${FAILURE_CODE})."
  exit 1
}

for required in B2_BUCKET_NAME B2_ENDPOINT B2_SOURCE_KEY_ID B2_SOURCE_APPLICATION_KEY B2_HLS_KEY_ID B2_HLS_APPLICATION_KEY; do
  if [[ -z "${!required:-}" ]]; then
    die "CONFIGURATION_ERROR"
  fi
done

if [[ ! "$B2_BUCKET_NAME" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
  die "CONFIGURATION_ERROR"
fi
B2_ENDPOINT="${B2_ENDPOINT%/}"
if [[ ! "$B2_ENDPOINT" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
  die "CONFIGURATION_ERROR"
fi

WORK_DIR="$(mktemp -d -t skillify-transcode.XXXXXX)" || die "WORKSPACE_FAILED"
INPUT_FILE="${WORK_DIR}/source.bin"
OUTPUT_DIR="${WORK_DIR}/hls"
mkdir -p "$OUTPUT_DIR"

# Download only the validated original object, using a read-only source key.
FAILURE_CODE="B2_DOWNLOAD_FAILED"
export AWS_ACCESS_KEY_ID="$B2_SOURCE_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$B2_SOURCE_APPLICATION_KEY"
if ! aws s3 cp "s3://${B2_BUCKET_NAME}/${SOURCE_OBJECT_KEY}" "$INPUT_FILE" \
  --endpoint-url "$B2_ENDPOINT" --region us-east-1 --only-show-errors --no-progress; then
  die "B2_DOWNLOAD_FAILED"
fi
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

# Probe the first video stream. Never upscale: only emit target heights at or below source height.
FAILURE_CODE="SOURCE_PROBE_FAILED"
if ! DIMENSIONS="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
  -of json "$INPUT_FILE" 2>/dev/null | jq -er '.streams[0] | "\(.width)x\(.height)"')"; then
  die "SOURCE_PROBE_FAILED"
fi
if [[ ! "$DIMENSIONS" =~ ^[0-9]+x[0-9]+$ ]]; then
  die "SOURCE_PROBE_FAILED"
fi
IFS='x' read -r SOURCE_WIDTH SOURCE_HEIGHT <<< "$DIMENSIONS"
if (( SOURCE_WIDTH < 1 || SOURCE_HEIGHT < 1 )); then
  die "SOURCE_PROBE_FAILED"
fi

TARGET_HEIGHTS=()
for target_height in 720 480 360; do
  if (( SOURCE_HEIGHT >= target_height )); then
    TARGET_HEIGHTS+=("$target_height")
  fi
done
if (( ${#TARGET_HEIGHTS[@]} == 0 )); then
  die "UNSUPPORTED_SOURCE_RESOLUTION"
fi

# Encode separate HLS VOD renditions. The same forced keyframe interval keeps
# segment boundaries aligned across qualities for smoother adaptive switching.
FAILURE_CODE="TRANSCODE_FAILED"
for target_height in "${TARGET_HEIGHTS[@]}"; do
  variant_dir="${OUTPUT_DIR}/${target_height}p"
  mkdir -p "$variant_dir"

  case "$target_height" in
    720) maxrate="2800k"; bufsize="5600k"; audio_rate="128k" ;;
    480) maxrate="1400k"; bufsize="2800k"; audio_rate="112k" ;;
    360) maxrate="800k";  bufsize="1600k"; audio_rate="96k" ;;
    *) die "CONFIGURATION_ERROR" ;;
  esac

  if ! ffmpeg -hide_banner -nostdin -y -loglevel warning \
    -i "$INPUT_FILE" \
    -map 0:v:0 -map '0:a:0?' \
    -vf "scale=-2:${target_height}" \
    -c:v libx264 -preset veryfast -profile:v main -pix_fmt yuv420p \
    -crf 22 -maxrate "$maxrate" -bufsize "$bufsize" \
    -force_key_frames 'expr:gte(t,n_forced*6)' -sc_threshold 0 \
    -c:a aac -b:a "$audio_rate" -ac 2 -ar 48000 \
    -f hls -hls_time 6 -hls_playlist_type vod -hls_flags independent_segments \
    -hls_segment_filename "${variant_dir}/segment_%05d.ts" \
    "${variant_dir}/playlist.m3u8"; then
    die "TRANSCODE_FAILED"
  fi

  if [[ ! -s "${variant_dir}/playlist.m3u8" ]] || \
     ! find "$variant_dir" -maxdepth 1 -type f -name 'segment_*.ts' -print -quit | grep -q .; then
    die "OUTPUT_MISSING"
  fi
done

# Construct an HLS master playlist with real encoded dimensions, not assumed dimensions.
MASTER_PLAYLIST="${OUTPUT_DIR}/master.m3u8"
{
  printf '#EXTM3U\n'
  printf '#EXT-X-VERSION:3\n'
  for target_height in "${TARGET_HEIGHTS[@]}"; do
    variant_dir="${OUTPUT_DIR}/${target_height}p"
    first_segment="$(find "$variant_dir" -maxdepth 1 -type f -name 'segment_*.ts' -print -quit)"
    [[ -n "$first_segment" ]] || die "OUTPUT_MISSING"
    if ! variant_dimensions="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
      -of json "$first_segment" 2>/dev/null | jq -er '.streams[0] | "\(.width)x\(.height)"')"; then
      die "OUTPUT_MISSING"
    fi
    if [[ ! "$variant_dimensions" =~ ^[0-9]+x[0-9]+$ ]]; then
      die "OUTPUT_MISSING"
    fi
    IFS='x' read -r variant_width variant_height <<< "$variant_dimensions"
    case "$target_height" in
      720) bandwidth=3200000 ;;
      480) bandwidth=1700000 ;;
      360) bandwidth=1000000 ;;
    esac
    printf '#EXT-X-STREAM-INF:BANDWIDTH=%s,RESOLUTION=%sx%s\n' "$bandwidth" "$variant_width" "$variant_height"
    printf '%sp/playlist.m3u8\n' "$target_height"
  done
} > "$MASTER_PLAYLIST"

if [[ ! -s "$MASTER_PLAYLIST" ]] || ! grep -q '^#EXT-X-STREAM-INF:' "$MASTER_PLAYLIST"; then
  die "OUTPUT_MISSING"
fi

# Upload media segments first, then playlists. HLS playlists are short-cache so
# they refresh promptly; immutable segment names can be cached for a long time.
FAILURE_CODE="B2_UPLOAD_FAILED"
export AWS_ACCESS_KEY_ID="$B2_HLS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$B2_HLS_APPLICATION_KEY"
if ! aws s3 cp "$OUTPUT_DIR/" "s3://${B2_BUCKET_NAME}/${OUTPUT_PREFIX}/" \
  --recursive --exclude '*.m3u8' --content-type 'video/mp2t' \
  --cache-control 'public,max-age=31536000,immutable' \
  --endpoint-url "$B2_ENDPOINT" --region us-east-1 --only-show-errors --no-progress; then
  die "B2_UPLOAD_FAILED"
fi

while IFS= read -r -d '' playlist_file; do
  relative_path="${playlist_file#"${OUTPUT_DIR}/"}"
  if ! aws s3 cp "$playlist_file" "s3://${B2_BUCKET_NAME}/${OUTPUT_PREFIX}/${relative_path}" \
    --content-type 'application/vnd.apple.mpegurl' \
    --cache-control 'public,max-age=60' \
    --endpoint-url "$B2_ENDPOINT" --region us-east-1 --only-show-errors --no-progress; then
    die "B2_UPLOAD_FAILED"
  fi
done < <(find "$OUTPUT_DIR" -type f -name '*.m3u8' -print0)

# Let the Supabase callback independently verify the master, variant playlists,
# and every referenced segment in B2 before marking the job completed.
FAILURE_CODE="CALLBACK_DELIVERY_FAILED"
COMPLETION_CALLBACK_ATTEMPTED=1
if ! send_callback "completed" "" "${OUTPUT_PREFIX}/master.m3u8"; then
  echo "::error::Completion callback did not return a successful response. Outputs were uploaded; inspect callback logs before retrying."
  exit 1
fi

# Success. The original MP4 is intentionally preserved and the courses.video_url
# field is intentionally not changed by this workflow.
echo "HLS output uploaded and completion callback accepted."
