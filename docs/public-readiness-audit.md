# FarPilot Public Readiness Audit

**Status:** NOT RUN

**Repository visibility:** Private

This committed file records only sanitized counts and dispositions. Raw scanner output, matching values, private paths, identity documents, and credentials must remain outside the repository in a mode-0600 private directory.

## Required checks

| Check | Status | Sanitized result |
|---|---|---|
| Current tracked tree scanner | Pending | Not run |
| Full reachable Git history scanner | Pending | Not run |
| Gitleaks `git --redact --log-opts="--all"` | Pending | Not run |
| FarPilot-specific prohibited-data review | Pending | Not run |
| Tracked large/generated-file review | Pending | Not run |
| Commit author/email review | Pending | Not run |
| Public documentation and workflow review | Pending | Not run |

## Scanner invocation boundary

The repository scanner writes both reports outside the repository:

```bash
python3 -I scripts/public_readiness_audit.py \
  --repo "$PWD" \
  --private-report "$CLAUDE_JOB_DIR/tmp/farpilot-public-audit-private.json" \
  --summary "$CLAUDE_JOB_DIR/tmp/farpilot-public-audit-summary.json"
```

Run the complementary scanner privately:

```bash
gitleaks git --redact --log-opts="--all" \
  --report-format json \
  --report-path "$CLAUDE_JOB_DIR/tmp/farpilot-gitleaks.json"
```

Do not commit either raw report. Update this document manually with category counts and dispositions only after reviewing them privately.

## Visibility gate

**Visibility change authorized:** No

Permitted final states:

- `NOT RUN`
- `BLOCKED`
- `READY FOR VISIBILITY REVIEW`

This document must never claim that the repository is safe to publish merely because the current working tree is clean. The full reachable history and external scanner must also pass or have reviewed dispositions.
