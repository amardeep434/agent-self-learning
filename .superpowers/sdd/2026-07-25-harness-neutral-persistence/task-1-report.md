# Task 1: Path Resolver — Implementation Report

## Summary

Successfully implemented the harness-neutral path resolver module as specified in the task brief. All 10 unit tests pass. The implementation provides a single source of truth for path resolution across the agent-self-learning framework, supporting Claude Code, GitHub Copilot CLI, and VS Code Copilot Chat as peers.

## Files Created

1. **`scripts/lib/paths.py`** (100 lines)
   - Main path resolver module
   - Implements three public functions: `resolve_home()`, `resolve_all()`, `legacy_home()`
   - CLI interface with `_main()` for `get <key>` and `all` commands
   - Platform-aware resolution following priority: explicit override > XDG_DATA_HOME > Windows LOCALAPPDATA > Linux/macOS ~/.local/share
   - Vendor-neutral naming (no `.claude` references)

2. **`tests/test-paths.py`** (90 lines)
   - Unit test suite with 3 test classes: `TestResolveHome`, `TestLegacyDetection`, `TestCli`
   - 10 total tests covering:
     - Explicit override precedence
     - XDG_DATA_HOME resolution
     - Linux/macOS/Windows platform defaults
     - Absence of `.claude` in any computed path
     - All required keys present in `resolve_all()` output
     - Legacy ~/.claude detection (present and absent)
     - CLI interface (single path output, unknown key error handling)

## Implementation Details

### Path Resolution Order
```
1. $AGENT_LEARNING_HOME         (explicit override, highest priority)
2. $XDG_DATA_HOME/agent-learning (Linux standard, if set)
3. %LOCALAPPDATA%\agent-learning (Windows, if on win32 platform)
4. ~/.local/share/agent-learning (Linux/macOS default fallback)
```

### Key Paths Produced by `resolve_all()`
- `home`: base directory
- `state`: `${home}/state`
- `skills`: `${home}/learned-skills`
- `memory`: `${home}/memory`
- `logs`: `${home}/logs`
- `sessions_db`: `${home}/sessions/search.db`
- `config_file`: `${home}/self-learning.conf`

### Legacy Detection
The `legacy_home()` function detects pre-neutral `~/.claude` stores by checking for the presence of either:
- `~/.claude/memory` directory
- `~/.claude/learned-skills` directory

This is detection-only; no data migration happens in this module. Users are responsible for migration after the `doctor` command alerts them.

## Test Execution

### Test Command
```bash
python3 tests/test-paths.py -v
```

### Full Output
```
test_get_prints_single_path (__main__.TestCli.test_get_prints_single_path) ... ok
test_get_unknown_key_exits_nonzero (__main__.TestCli.test_get_unknown_key_exits_nonzero) ... ok
test_legacy_none_when_absent (__main__.TestLegacyDetection.test_legacy_none_when_absent) ... ok
test_legacy_reported_when_present (__main__.TestLegacyDetection.test_legacy_reported_when_present) ... ok
test_all_keys_present (__main__.TestResolveHome.test_all_keys_present) ... ok
test_explicit_override_wins (__main__.TestResolveHome.test_explicit_override_wins) ... ok
test_linux_default (__main__.TestResolveHome.test_linux_default) ... ok
test_no_claude_in_any_default (__main__.TestResolveHome.test_no_claude_in_any_default) ... ok
test_windows_uses_localappdata (__main__.TestResolveHome.test_windows_uses_localappdata) ... ok
test_xdg_used_when_set (__main__.TestResolveHome.test_xdg_used_when_set) ... ok

----------------------------------------------------------------------
Ran 10 tests in 0.050s

OK
```

### Test Result
✓ **All 10 tests pass** (100% pass rate)

## Commit Details

**Commit SHA:** `3e6b418`

**Commit Message:**
```
feat(paths): platform-aware vendor-neutral path resolver
```

**Files Changed:** 2 files (174 insertions, 0 deletions)
- `scripts/lib/paths.py` (created)
- `tests/test-paths.py` (created)

## TDD Process Followed

1. ✓ **Step 1**: Created failing test file
2. ✓ **Step 2**: Verified test fails with `ModuleNotFoundError: No module named 'paths'`
3. ✓ **Step 3**: Implemented `scripts/lib/paths.py`
4. ✓ **Step 4**: Verified all 10 tests pass
5. ✓ **Step 5**: Committed with conventional-commit prefix

## Deviations from Brief

None. Implementation exactly matches the brief's provided code for both test and implementation.

## Assumptions & Notes

1. **Python version compatibility**: Code uses `from __future__ import annotations` to support Python 3.9+ with modern type hint syntax (`dict | None`).

2. **Environment isolation in tests**: Tests use `_env()` helper to filter out unrelated environment variables before each test, ensuring isolation and repeatability across different developer machines.

3. **Platform detection**: The `platform` parameter defaults to `sys.platform` when not provided, allowing easy testing across simulated platforms without actual OS context switching.

4. **Backward compatibility**: The implementation proactively includes `legacy_home()` for migration support, even though data migration itself is deferred to a future "doctor" tool. This ensures users with existing `~/.claude` stores can be properly detected and guided.

5. **Subpath construction**: The `_SUBPATHS` dictionary uses tuples of path components that are unpacked via `joinpath(*parts)`, allowing for nested paths like `sessions/search.db` without string manipulation.

## Concerns

None. The implementation is straightforward, well-tested, and aligns perfectly with the framework's requirements for vendor-neutral, platform-aware path resolution.
