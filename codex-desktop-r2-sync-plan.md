# Codex Desktop and Codex++ R2-only sync Contract

```toml
goal = "从官方上游同步未修改的 Windows x64 Codex Desktop 与 Codex++ 三平台字节到 Cloudflare R2，并在所有分片验证完成后更新稳定 latest.json"
base = "6773b2445e3b51c31fb84387d5ea2a9fa40e20db"

[scope]
allow = [
  ".github/workflows/sync.yml",
  ".github/workflows/gitee-api-smoke.yml",
  "scripts/publish-r2-mirror.sh",
  "codex-desktop-r2-sync-plan.md",
  "codex-desktop-gitee-sync-plan.md",
]
deny = [
  ".env",
  "**/*token*",
  "**/*.key",
  "**/*.pem",
]

[[checks]]
cmd = "python -c \"import pathlib,yaml; p=pathlib.Path('.github/workflows/sync.yml'); data=yaml.safe_load(p.read_text(encoding='utf-8')); assert data['name'].startswith('Sync official'); assert data['jobs']['mirror-codex-desktop-r2']['env']['MIRROR_ID']=='codex-mirror'; assert data['jobs']['mirror-codexplusplus-r2']['env']['MIRROR_ID']=='codexplusplus-mirror'; assert 'GITEE_TOKEN' not in data['jobs']['mirror-codex-desktop-r2']['env']; assert 'GITEE_TOKEN' not in data['jobs']['mirror-codexplusplus-r2']['env']\""

[[checks]]
cmd = "python -c \"import pathlib,yaml; p=pathlib.Path('.github/workflows/sync.yml'); data=yaml.safe_load(p.read_text(encoding='utf-8')); jobs=data['jobs']; assert data['permissions']['contents']=='read'; assert jobs['publish-staging-release']['permissions']['contents']=='write'; assert jobs['validate-r2-config']; assert jobs['download-windows']['needs']=='validate-r2-config'; assert 'if' not in jobs['mirror-codex-desktop-r2']; assert jobs['mirror-codexplusplus-r2']['needs']=='validate-r2-config'; assert str(jobs['mirror-codex-desktop'].get('if','')).strip().lower() in ('false','${{ false }}'); assert str(jobs['mirror-codexplusplus'].get('if','')).strip().lower() in ('false','${{ false }}'); smoke=yaml.safe_load(pathlib.Path('.github/workflows/gitee-api-smoke.yml').read_text(encoding='utf-8')); assert str(smoke['jobs']['verify-attachment-upload'].get('if','')).strip().lower() in ('false','${{ false }}')\""

[[checks]]
cmd = "python -c \"import pathlib; workflow=pathlib.Path('.github/workflows/sync.yml').read_text(encoding='utf-8').lower(); publisher=pathlib.Path('scripts/publish-r2-mirror.sh').read_text(encoding='utf-8').lower(); assert 'gitee_token' not in workflow.split('mirror-codex-desktop-r2:',1)[1].split('mirror-codexplusplus:',1)[0]; assert 'gitee_token' not in workflow.split('mirror-codexplusplus-r2:',1)[1]; assert 'gitee' not in publisher; assert 'https://download.z8.hk' in publisher; assert 'set -euo pipefail; upload_part' in publisher; assert 'set -euo pipefail; verify_part' in publisher; assert 'signtool.exe' in workflow; assert 'appxmanifest.xml' in workflow\""

[[checks]]
cmd = "git diff --check"
```

## Authority and limits

- GitHub upstream remains the version authority. The workflow resolves official
  Desktop metadata and stable Codex++ Release assets, verifies exact byte size
  and SHA-256, and uploads the original bytes without repackaging. The current
  Desktop scope is Windows x64 MSIX; Codex++ includes Windows x64, macOS Intel,
  and macOS Apple Silicon assets. Codex Desktop macOS remains on the official
  fallback route until a separately verified source is adopted.
- Cloudflare R2 is the only public artifact transport. Gitee jobs and the old
  Gitee publisher are retained only as historical rollback material and are not
  part of the active workflow.
- Each mirror writes immutable parts and a versioned manifest below
  `z8-launch/<mirror-id>/<tag>/`. The stable pointer is
  `z8-launch/<mirror-id>/latest.json` and is published only after public
  re-download verification succeeds.
- R2 lifecycle cleanup is an owner-side Cloudflare setting, not a workflow
  deletion step: keep the two stable pointers permanently and expire versioned
  parts/manifests after 90 days. This bounds storage cost without risking the
  current release during a sync.
- Cloudflare caching is also an owner-side rule: bypass every path ending in
  `/latest.json`, and make the remaining immutable paths below `/z8-launch/`
  cache-eligible while respecting origin `Cache-Control`. A repeated
  `cf-cache-status: DYNAMIC` does not count as CDN acceleration proof.
- The script keeps the logical manifest identifiers `z8hk/codex-mirror` and
  `z8hk/codexplusplus-mirror` for client compatibility, but it never contacts
  Gitee and never requires `GITEE_TOKEN`.
- This Contract does not authorize changing repository visibility, deleting
  objects, or exposing any secret.

## Change impact

- CHG-R2-WF-001: remove Gitee credentials and pointer updates from active R2
  jobs and use explicit logical mirror IDs.
- CHG-R2-PUB-001: read the current stable R2 pointer for idempotency and publish
  the stable pointer after all immutable parts and the versioned manifest pass
  verification.
- CHG-R2-PUB-002: reject a non-owner public URL, a custom version prefix, or a
  same-tag object whose size/SHA-256 metadata differs from the verified source.
- CHG-R2-WF-002: fail early when the five R2 settings are missing or invalid,
  and verify the Windows MSIX package identity plus its Authenticode chain
  before any R2 upload.
- EFF-R2-WF-001 must-change: a scheduled run succeeds with only R2 credentials
  and repository variables.
- EFF-R2-PUB-001 must-change: clients can resolve one fixed latest URL while
  previous versioned objects remain immutable.
- EFF-R2-PUB-002 must-not-change: upstream identity, integrity checks, bounded
  part sizes, retry behavior, and no-repackaging policy.
- CHK-R2-001: YAML, disabled-Gitee, and environment contract assertions.
- CHK-R2-002: publisher diff and public-manifest verification after the next
  Actions run.
- CHK-R2-003: Bash syntax and immutable-prefix/idempotency checks for the
  publisher.
