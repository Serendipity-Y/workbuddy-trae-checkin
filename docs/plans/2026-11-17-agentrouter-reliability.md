# AgentRouter reliability implementation plan

**Goal:** Make manual refresh and the daily task use the same login/query/push flow and make stale data and failures visible.

**Architecture:** Preserve existing Worker API contracts and account encryption. Replace only the dashboard refresh logic and Windows helper; patch the installed Python script without reading or replacing its configuration. Both Windows entry points use the same Python process lock. A guarded installer backs up only touched files and can restore them.

**Tech Stack:** Existing Worker JavaScript, Node standard library, Python standard library plus the installed httpx, Windows PowerShell 5.1.

1. Reproduce silent failure, unbounded wait, unrelated platform blocking, missing automatic list refresh, and helper false success with synthetic responses. No live sign-in in unit tests.
2. Fix dashboard with independent per-platform reads, explicit HTTP/business failures, bounded requests, visible balance collection timestamps and read-only polling. Keep manual run semantics explicit.
3. Make the Windows helper call the same run-checkin.cmd as the daily task, handle exit status/timeout/busy without disclosing child output. Patch Python to require a valid quota and acknowledged push, accept zero, and serialize all login runs.
4. Test the helper with mocked child processes, the Python patch against an equivalent credential-free fixture, and dashboard behavior with a fake DOM and timers.
5. Build a guarded PowerShell installer: verify paths/baselines, generate and compile the Python patch before replacing anything, verify backups and final hashes, restart only the identified helper, verify endpoints, provide rollback. Never overwrite .env, .dev.vars, KV, logs, or scheduled task configuration.
6. Apply to the user's Windows machine through the shared installer, then verify the live page, helper version, one end-to-end refresh and the saved balance timestamp. Reconcile any uncertain refresh outcome read-only before retrying.

The user already authorized implementation and repair. No new approval checkpoint is needed. No GitHub push is included in this task.
