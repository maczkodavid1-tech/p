---
name: FlyMyAI image generation
description: FlyMyAI endpoint and routing constraints for this Nim agent runtime.
---

The FlyMyAI base URL must be configured without the `/api/v1` suffix because the runtime appends `/api/v1/<owner>/<project>/predict`. Adult image requests use Seedream with up to fourteen reference fields; general image requests use GPT Image with one reference field.

**Why:** A base URL containing the API path creates a duplicated request path and prevents provider calls from reaching the prediction endpoint.

**How to apply:** Keep `FLYMYAI_BASE_URL` at the host root and let the image generation client construct the versioned prediction URL.