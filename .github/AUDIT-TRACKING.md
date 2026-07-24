# Audit Findings Tracker

**Repository:** github.com/mathewcsims/self-hosted  
**Audit Report:** [.github/AUDIT-2026-07-24.md](AUDIT-2026-07-24.md)  
**Last Updated:** July 24, 2026  

---

## Status Summary

| Category | Total | Resolved | Open | % Complete |
|----------|-------|----------|------|------------|
| **Critical** | 0 | 0 | 0 | 100% |
| **High** | 0 | 0 | 0 | 100% |
| **Medium** | 2 | 1 | 1 | 50% |
| **Low** | 10 | 0 | 10 | 0% |
| **Informational** | 12 | 1 | 11 | 8% |
| **TOTAL** | **34** | **2** | **32** | **6%** |

---

## Resolution Log

| Date | Finding ID | Category | Severity | Description | Action Taken | Commit | Status |
|------|------------|----------|----------|-------------|--------------|--------|--------|
| 2026-07-24 | BP-006 | Best Practices | Medium | No documented restore test procedure | Added comprehensive restore test procedure to SETUP.md | [1a54c03](https://github.com/mathewcsims/self-hosted/commit/1a54c030d1bdcffe364846bcde40d11fba12030c) | ✅ RESOLVED |
| 2026-07-24 | INF-012 | Best Practices | Informational | No restore test procedure | Same as BP-006 | [1a54c03](https://github.com/mathewcsims/self-hosted/commit/1a54c030d1bdcffe364846bcde40d11fba12030c) | ✅ RESOLVED |

---

## Open Findings

### Medium Priority (1)

| ID | Category | Severity | Finding | Evidence | Recommendation | Effort | Status |
|----|----------|----------|---------|----------|----------------|--------|--------|
| BP-003 | Best Practices | Medium | Karakeep Chrome image unmaintained | `karakeep/compose.yaml` line 141 | Document in compose.yaml, consider `browserless/chrome` replacement | 1-2 hours | ⏳ OPEN |

---

### Low Priority (10)

| ID | Category | Finding | Evidence | Recommendation | Effort |
|----|----------|---------|----------|----------------|--------|
| DOC-001 | Documentation | No ToC in SETUP.md | `SETUP.md` | Consider adding ToC | Medium |
| DOC-002 | Documentation | Some SETUP.md sections very long | Vikunja section | Consider subsections | Medium |
| SEC-001 | Security | Tailscale IPv6 range hardcoded | `pf-lockdown/` line 62 | Document as assumption | Low |
| SEC-002 | Security | Pi link-local IPv6 hardcoded | `pf-lockdown/` line 62 | Document as assumption | Low |
| SEC-004 | Security | No image signing | All images | Consider Cosign for critical images | Medium |
| SEC-005 | Security | Proton Pass single point of failure | All secrets | Document recovery procedure | Low |
| SEC-009 | Security | Trivy excludes .DS_Store | `trivy-scan/scan.py` line 68 | Add to EXCLUDE_DIRS | Low |
| SEC-010 | Security | No log retention policy | Various logs | Document retention policy | Low |
| BP-001 | Best Practices | Inconsistent directory naming | `memos-prospect-ukri-tus/` vs `owl/` | Document naming convention | Low |
| BP-007 | Best Practices | No backup verification documented | `kopia-mac/backup.sh` | Kopia has built-in verification | Low |

---

### Informational (11)

| ID | Category | Finding | Note |
|----|----------|---------|------|
| INF-001 | Best Practices | No CI/CD pipeline | Not needed for personal project |
| INF-002 | Best Practices | No pre-commit hooks | Not critical |
| INF-003 | Best Practices | No centralized log aggregation | Overkill for scale |
| INF-004 | Best Practices | No metrics collection | Not needed |
| INF-005 | Best Practices | No automated tests | Not practical for IaC |
| INF-006 | Documentation | No CONTRIBUTING.md | Not critical for personal |
| INF-007 | Security | No secret rotation automation | Manual is acceptable |
| INF-008 | Security | ntfy default-deny could be stricter | Current is adequate |
| INF-009 | Best Practices | Some app-level rate limiting missing | Caddy compensates |
| INF-010 | Documentation | SETUP.md could be split | Current works well |
| INF-011 | Security | Caddyfile mc37 hardcoded | Acceptable |

---

## Next Actions

### Short-Term (Next 30 Days)

1. **BP-003: Karakeep Chrome Image**
   - Add warning comment to `karakeep/compose.yaml`
   - Research `browserless/chrome` as replacement
   - **Effort:** 1-2 hours
   - **Priority:** Medium

---

### Long-Term (Next 90 Days)

| ID | Action | Effort | Priority |
|----|--------|--------|----------|
| DOC-001 | Add ToC to SETUP.md | 2-3 hours | Low |
| SEC-005 | Document Proton Pass recovery procedure | 2-3 hours | Low |
| SEC-004 | Research Cosign image signing | 4-8 hours | Low |
| INF-006 | Add CONTRIBUTING.md | 1-2 hours | Low |

---

## Historical Resolutions

### 2026-07-24

- **BP-006:** Added comprehensive restore test procedure to SETUP.md
  - Includes: importance statement, recommended frequency, step-by-step commands, verification steps, automation suggestions, documentation guidance
  - Commit: [1a54c03](https://github.com/mathewcsims/self-hosted/commit/1a54c030d1bdcffe364846bcde40d11fba12030c)

---

## Usage

### Updating Status

When a finding is resolved:

1. Update the **Resolution Log** table with the resolution details
2. Update the **Open Findings** section (remove resolved items)
3. Update the **Status Summary** counts
4. Update the **Historical Resolutions** section
5. Commit with message: `Update audit tracking: resolve <ID>`

### Adding New Findings

When new issues are discovered:

1. Add to the appropriate **Open Findings** section
2. Update the **Status Summary** counts
3. Commit with message: `Update audit tracking: add <ID>`

---

## Links

- [Full Audit Report](AUDIT-2026-07-24.md)
- [Repository](https://github.com/mathewcsims/self-hosted)
- [GitHub Issues](https://github.com/mathewcsims/self-hosted/issues)
