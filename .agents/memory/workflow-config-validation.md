---
name: Workflow configuration validation
description: Platform constraint for changing the project's .replit workflow configuration.
---

Use a temporary full TOML file and the platform's validated replacement flow when changing `.replit`; direct file edits are rejected.

**Why:** The environment protects workflow configuration from unvalidated direct edits.

**How to apply:** Preserve the existing TOML structure, write the candidate configuration to a workspace temporary file, validate and replace it, then restart the exact configured workflow.