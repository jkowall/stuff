---
name: macos-updater-health
description: "Diagnose the health of a manual or launchd-scheduled macOS package updater using source, cached-script, scheduler, log, PATH, and prerelease-channel evidence. Use when an updater was skipped, appeared successful despite failed phases, ran stale code, or resolved the wrong CLI version."
---

# macOS Updater Health

Diagnose whether a macOS package updater ran the intended code and whether each package-manager phase succeeded. Treat diagnosis as the default scope. Do not run updates, terminate sessions, reload launchd jobs, change package channels, or edit system state unless the user explicitly asks.

## Stable Inputs

Collect or discover:

- The source updater script and its setup/install script.
- The launchd label, plist, cached script or wrapper, and expected schedule.
- The expected run time or symptom window, including timezone.
- The log location and expected package-manager phases.
- Any intentionally configured prerelease package names, dist-tags, install prefix, and executable path.

If an input is unknown, discover it from the current source and launchd configuration. Never infer a label, path, channel, or successful run from an old note.

## Evidence Rules

Use current primary evidence in this order:

1. Repository instructions and the current source and setup scripts.
2. The loaded launchd job, plist, program arguments, and cached executable copy.
3. Timestamped logs covering the expected run window and every updater phase.
4. Current package configuration, installed versions, and executable resolution.

Record the time and timezone of every state query. A scheduler process exit of `0` proves only that the launched process exited cleanly; it does not prove that Homebrew, Mac App Store, npm, or another internal phase succeeded.

## Procedure

### 1. Establish Scope and Safety

- Confirm whether the request is diagnosis, repair, or a live update. Continue read-only when it is ambiguous.
- Read repository-local instructions and both the updater and setup scripts before interpreting state.
- Preserve unrelated work and redact credentials or private configuration values from commands, logs, diffs, and output.
- Check for an active updater process, but do not kill it or start a second run.

### 2. Build the Expected-Behavior Map

From the current scripts, list:

- Each package-manager phase in execution order.
- How each phase records start, completion, skipped state, warning, and failure.
- Whether a failed phase stops the script or is intentionally accumulated for a final status.
- The expected interpreter, environment, working directory, PATH construction, log destination, and schedule.
- Any package excluded from generic updates because it is installed through a named prerelease dist-tag or isolated prefix.

Do not assume all phases share the wrapper's final exit status.

### 3. Inspect Live launchd State

- Query the applicable user or system launchd domain with `launchctl print`.
- Capture the loaded label, program and arguments, run count, current state, last exit status, throttle or error fields, and scheduling fields that are actually present.
- Compare those values with the current plist and setup script.
- Treat absent or version-dependent fields as unknown, not as success or failure.

`launchctl list` or the existence of a plist alone is insufficient proof that the intended job ran.

### 4. Compare Source and Cached Code

- Resolve the source script and the exact file or wrapper launchd executes.
- Compute and report cryptographic hashes for both files when they should be byte-identical.
- If a generated wrapper is expected to differ, compare its embedded source path, arguments, environment, and payload rather than declaring drift from a hash mismatch alone.
- Use a focused diff to identify material drift. Distinguish an unloaded new source from a loaded stale cache.

### 5. Reconstruct the Run from Logs

- Select logs by the expected run window, not merely by newest filename.
- Locate the wrapper start and finish plus each phase's start, result, and error evidence.
- Correlate timestamps with launchd state and script duration.
- Classify every expected phase as `succeeded`, `failed`, `skipped-intentionally`, `not-reached`, or `unknown`.
- Preserve the exact error location and a short sanitized excerpt. Do not expose tokens, private paths, or configuration values.

If the log shows only a wrapper completion or final exit code, report phase health as unknown.

### 6. Verify PATH and Prerelease Intent

For every intentionally prerelease CLI:

- Read the configured package name, dist-tag, and install prefix from the current script or approved configuration.
- Verify the current registry dist-tag only when network access is authorized and needed.
- Inspect the installed package version and the executable paths resolved by both the interactive shell and the launchd environment.
- Resolve all candidates, symlinks, and prefix-local binaries. Confirm that the updater invoked the intended executable.
- Compare configured tag, tag-selected version, installed version, resolved path, and log evidence as separate facts.

Do not replace a prerelease channel with `latest`, or assume a globally installed binary wins PATH resolution.

### 7. Diagnose and Bound the Fix

Choose the narrowest supported cause:

- Scheduler or load-state failure.
- Source-to-cache drift.
- Individual package-manager phase failure.
- PATH, prefix, or prerelease-channel mismatch.
- Permission, environment, network, or lock contention.
- Healthy run with no reproduced failure.
- Insufficient evidence.

State confidence and the evidence that would falsify the conclusion. If repair is explicitly requested, propose or apply the smallest reversible correction, then repeat the relevant state, hash, path, and log checks. Do not use a live full update as the first verification when a read-only or targeted check can prove the correction.

## Output Schema

Return a compact report with:

1. **Conclusion**: healthy, degraded, failed, stale, or indeterminate; include confidence.
2. **Observation window**: timestamps and timezone.
3. **Scheduler state**: label, loaded state, executable, run evidence, and last exit status.
4. **Source versus cache**: paths, hashes or structural comparison, and material drift.
5. **Phase results**:

   | Phase | Expected | Log evidence | Result | Failure or skip reason |
   |---|---|---|---|---|

6. **CLI resolution**:

   | Package | Configured tag | Selected/installed version | Resolved path | Verdict |
   |---|---|---|---|---|

7. **Root cause and next action**: one evidence-backed recommendation; list any authorization required.
8. **Unknowns**: missing logs, inaccessible state, or unverified network facts.

## Stop Conditions

Stop when one of these is true:

- Health is proven by matching source/cache intent, live scheduler state, complete per-phase logs, and correct CLI resolution.
- A cause is localized with enough evidence to recommend a bounded correction.
- Required logs, files, permissions, or current state are unavailable; report the exact blocker and next read-only check.
- The next action would run updates, terminate a process, reload a job, change channels, or otherwise mutate system state without explicit authorization.

Never claim full health from an exit code alone.
