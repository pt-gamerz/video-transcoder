# Skillify video transcoder

This repository contains the GitHub Actions worker used by Skillify to convert uploaded course videos into adaptive HLS streams. **This is the repository that must run transcoding jobs**; the separate `skillify-video-generation` repository is for marketing-content automation.

## Workflow

Workflow file: [`.github/workflows/transcode.yml`](.github/workflows/transcode.yml)

The workflow supports two triggers:

- **`repository_dispatch`** with event type `transcode_lesson`. The JSON `client_payload` must contain `lesson_id`, `job_id`, and `source_object_key`.
- **Manual `workflow_dispatch`** from the Actions tab. It has a **standalone test mode** that does not need a database job record, and an integrated mode for real queued jobs.

`lesson_id` is the UUID of the existing row in Skillify's `courses` table. In standalone test mode, leave `job_id` blank; the workflow generates a temporary UUID used only to name the HLS output folder. It does not insert a `video_transcode_jobs` row and does not call Supabase. In integrated mode, `job_id` must be the UUID of an existing `video_transcode_jobs` row. `source_object_key` is the exact Backblaze B2 object key of the uploaded original, not a URL or file ID. It must follow:

```text
courses/videos/<course-or-lesson-folder>/<filename>
```

The course UUID and generated/provided run UUID are validated before the video worker starts. For standalone testing, no database job UUID is needed. For integrated mode, use the actual UUID from the database; do not invent one.

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
| `SUPABASE_URL` | Project URL used for the completion/failure callback in integrated mode |
| `TRANSCODE_CALLBACK_SECRET` | Shared secret expected by the `transcode-callback` Edge Function in integrated mode |

Use a read-only B2 key for the source credentials and a separate write-capable key scoped to the HLS output for the HLS credentials. Secret values are never printed by the workflow. An early validation step reports only the names of missing secrets.

## Processing and outputs

The worker:

1. Downloads the validated original from B2 using the source/read credentials.
2. Probes the source and creates renditions at 720p, 480p, and 360p only when each rendition does not exceed the source height. It never upscales.
3. Creates an HLS master playlist and variant playlists.
4. Uploads media segments first and playlists second using the HLS/write credentials.
5. In integrated mode, calls `/functions/v1/transcode-callback` with the course and job identifiers. The callback independently verifies the uploaded manifest and referenced files before the job is marked complete. Standalone test mode deliberately skips this callback and does not update Supabase.
6. Preserves the original MP4. The worker does not overwrite `courses.video_url`.

HLS output is written under:

```text
courses/hls/<lesson_id>/<job_id>/
```

The GitHub Actions job has a six-hour timeout. B2 operations use retry settings, bounded connection/read timeouts, and sanitized error output to make failures easier to diagnose without exposing credentials.

## Operational notes

- For a technical B2/FFmpeg/HLS test, select standalone test mode, enter the existing course UUID and exact source key, and leave `job_id` blank. The workflow generates a temporary output-folder UUID. A successful standalone test does **not** mark the course as transcoded or change Supabase.
- For integrated testing/production, turn standalone test mode off and provide a real existing `video_transcode_jobs.id`. The database job row must be created by the application/job-creation process before dispatch.
- The upload source key must match the actual B2 object key exactly.
- If a run fails, check the Actions log for the failing stage and the safe B2 S3 error details. Never paste application-key values into logs or support messages.
