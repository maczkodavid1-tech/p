---
name: PTY WebSocket lifecycle
description: Reliability constraints for the persistent InstaVM PTY WebSocket client.
---

The persistent PTY client must serialize outbound frames without blocking the async event loop, keep the reader alive for the task lifetime, and bound both frame and accumulated output sizes.

**Why:** Concurrent tool calls can interleave frames, and an unbounded or malformed remote frame can corrupt the connection or exhaust backend memory.

**How to apply:** Use cooperative wait state for frame writes, close and remove the task connection on protocol or socket errors, and validate reserved bits, server masking, control-frame limits, and output size.