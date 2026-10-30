# Skillify video transcoder

This repository contains the GitHub Actions worker used by Skillify to convert uploaded course videos into adaptive HLS streams. **This is the repository that must run transcoding jobs**; the separate `skillify-video-generation` repository is for marketing-content automation.

## Workflow

Workflow file: [`.github/workflows/transcode.yml`](.github/workflows/transcode.yml)

The workflow supports two triggers:

- **`repository_dispatch`** with event type `transcode_lesson`. The JSON `client_payload` must contain `lesson_id`, `job_id`, and `source_object_key`.
- **Manual `workflow_dispatch`** from the Actions tab. Supply the same three values as the named inputs.

`lesson_id` is the UUID of the existing row in Skillify's `courses` table. `job_id` must be the UUID of the existing `video_transcode_jobs` row. The worker does not create either database row. `source_object_key` is the exact Backblaze B2 object key of the uploaded original, not a URL or file ID. It must follow:

```text
courses/videos/<course-or-lesson-folder>/<filename>
```

Both UUIDs are validated before the video worker starts. Do not use labels such as `test-transcode-003` as a job ID; use a real UUID associated with the job row.

Example repository-dispatch payload:

```json
{
  "event_type": "transcode_lesson",
  "client_payload": {
    "lesson_id": "00000000-0000-4000-8000-000000000001",
    "job_id": "00000000-0000-4000-8000-000000000002",
    "source_object_key": "courses/videos/example-course/lesson-01.mp4"
  }
}
```

The example UUIDs and object key above are illustrative only; replace them with real values.

## Required GitHub Actions repository secrets

Configure these in **Settings → Secrets and variables → Actions → Repository secrets** for **`pt-gamerz/video-transcoder`**:

| Secret name | Purpose |
|---|---|
| `B2_BUCKET_NAME` | B2 bucket containing original and HLS objects |
| `B2_ENDPOINT` | S3-compatible endpoint for the B2 bucket's region |
| `B2_SOURCE_KEY_ID` | B2 application-key ID used to read original videos |
| `B2_SOURCE_APPLICATION_KEY` | B2 application key used to read original videos |
| `B2_HLS_KEY_ID` | B2 application-key ID used to write HLS output |
| `B2_HLS_APPLICATION_KEY` | B2 application key used to write HLS output |
| `SUPABASE_URL` | Project URL used for the completion/failure callback |
| `TRANSCODE_CALLBACK_SECRET` | Shared secret expected by the `transcode-callback` Edge Function |

Use a read-only B2 key for the source credentials and a separate write-capable key scoped to the HLS output for the HLS credentials. Secret values are never printed by the workflow. An early validation step reports only the names of missing secrets.

## Processing and outputs

The worker:

1. Downloads the validated original from B2 using the source/read credentials.
2. Probes the source and creates renditions at 720p, 480p, and 360p only when each rendition does not exceed the source height. It never upscales.
3. Creates an HLS master playlist and variant playlists.
4. Uploads media segments first and playlists second using the HLS/write credentials.
5. Calls `/functions/v1/transcode-callback` with the course and job identifiers. The callback is responsible for independently verifying the uploaded manifest and referenced files before the job is marked complete.
6. Preserves the original MP4. The worker does not overwrite `courses.video_url`.

HLS output is written under:

```text
courses/hls/<lesson_id>/<job_id>/
```

The GitHub Actions job has a six-hour timeout. B2 operations use retry settings, bounded connection/read timeouts, and sanitized error output to make failures easier to diagnose without exposing credentials.

## Operational notes

- A manual workflow run still requires a real existing course row UUID and transcode-job row UUID. It is not a substitute for creating the database job record.
- The upload source key must match the actual B2 object key exactly.
- If a run fails, check the Actions log for the failing stage and the safe B2 S3 error details. Never paste application-key values into logs or support messages.
