# Codex Desktop and Codex++ R2-only sync Contract

```toml
goal = "从官方上游同步未修改的 Windows x64 Codex Desktop 与 Codex++ 三平台字节到 Cloudflare R2，并在所有分片验证完成后更新稳定 latest.json；不创建额外的 GitHub Release"
base = "6773b2445e3b51c31fb84387d5ea2a9fa40e20db"

[scope]
allow = [
  ".github/workflows/sync.yml",
  ".github/workflows/gitee-api-smoke.yml",
  "scripts/publish-r2-mirror.sh",
  "scripts/resolve-codex-msix.ps1",
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
cmd = "python -c \"import pathlib,yaml; p=pathlib.Path('.github/workflows/sync.yml'); data=yaml.safe_load(p.read_text(encoding='utf-8')); jobs=data['jobs']; assert data['permissions']['contents']=='read'; assert 'publish-staging-release' not in jobs; assert jobs['validate-r2-config']; assert jobs['download-windows']['needs']=='validate-r2-config'; assert jobs['download-windows']['steps'][-1]['with']['compression-level']==0; assert 'if' not in jobs['mirror-codex-desktop-r2']; assert jobs['mirror-codexplusplus-r2']['needs']=='validate-r2-config'; assert str(jobs['mirror-codex-desktop'].get('if','')).strip().lower() in ('false','${{ false }}'); assert str(jobs['mirror-codexplusplus'].get('if','')).strip().lower() in ('false','${{ false }}'); smoke=yaml.safe_load(pathlib.Path('.github/workflows/gitee-api-smoke.yml').read_text(encoding='utf-8')); assert str(smoke['jobs']['verify-attachment-upload'].get('if','')).strip().lower() in ('false','${{ false }}')\""

[[checks]]
cmd = "python -c \"import pathlib; workflow=pathlib.Path('.github/workflows/sync.yml').read_text(encoding='utf-8').lower(); publisher=pathlib.Path('scripts/publish-r2-mirror.sh').read_text(encoding='utf-8').lower(); assert 'gitee_token' not in workflow.split('mirror-codex-desktop-r2:',1)[1].split('mirror-codexplusplus:',1)[0]; assert 'gitee_token' not in workflow.split('mirror-codexplusplus-r2:',1)[1]; assert 'gitee' not in publisher; assert 'https://download.z8.hk' in publisher; assert 'set -euo pipefail; upload_part' in publisher; assert 'set -euo pipefail; verify_part' in publisher; assert 'public,max-age=31536000,immutable' in publisher; assert '--cache-control ' + chr(39) + 'no-cache' + chr(39) in publisher; assert 'signtool.exe' in workflow; assert 'appxmanifest.xml' in workflow\""

[[checks]]
cmd = "python -c \"import pathlib; workflow=pathlib.Path('.github/workflows/sync.yml').read_text(encoding='utf-8'); resolver=pathlib.Path('scripts/resolve-codex-msix.ps1').read_text(encoding='utf-8'); assert 'downloadCandidates' in workflow; assert 'candidateUri.Scheme -notin' in workflow; assert 'packageVersion' in workflow; assert 'candidateUri.Scheme -notin' in resolver; assert 'actions/checkout@v4' not in workflow; assert 'actions/upload-artifact@v4' not in workflow; assert 'actions/download-artifact@v4' not in workflow; assert 'actions/checkout@v7' in workflow; assert 'actions/upload-artifact@v7' in workflow; assert 'actions/download-artifact@v8' in workflow; assert '757b9678cd2c774e8c305febbfb6fc52ce822d33cc000cb4864a8147c69aa923' in resolver; assert resolver.index('Get-FileHash') < resolver.index('Invoke-Expression'); assert resolver.index('Invoke-WebRequest -Uri $resolverUri') < resolver.index('$PSDefaultParameterValues[$restSkipKey] = $true')\""

[[checks]]
cmd = "python -c \"import pathlib,yaml; jobs=yaml.safe_load(pathlib.Path('.github/workflows/sync.yml').read_text(encoding='utf-8'))['jobs']; steps=[step for job in jobs.values() for step in job.get('steps',[]) if step.get('uses') == 'actions/checkout@v7']; assert steps and all(step.get('with',{}).get('persist-credentials') is False for step in steps)\""

[[checks]]
cmd = "python -c \"import pathlib; s=pathlib.Path('scripts/publish-r2-mirror.sh').read_text(encoding='utf-8'); assert 'xargs -0 -r -n 1 -P' in s; assert 'mv --' in s; assert 'upload_queue' in s; assert 'xargs -0 -r -n 3 -P' in s; assert 'upload_part ' + chr(34) + chr(36) + '1' + chr(34) in s\""

[[checks]]
cmd = "python -c \"import pathlib; s=pathlib.Path('.github/workflows/sync.yml').read_text(encoding='utf-8'); assert 'pids=()' in s; assert 'wait ' + chr(34) + chr(36) + '{pid}' + chr(34) in s; assert 'asset-specs/*.json' in s; assert 'mkdir -p upstream-assets asset-specs' in s\""

[[checks]]
cmd = "python -c \"import pathlib; s=pathlib.Path('scripts/publish-r2-mirror.sh').read_text(encoding='utf-8'); stable='aws s3 cp ' + chr(34) + '${manifest}' + chr(34) + ' ' + chr(34) + 's3://${R2_BUCKET}/${R2_LATEST_KEY}' + chr(34); assert s.index('verify_public_object ' + chr(34) + '${versioned_latest_url}' + chr(34)) < s.index(stable); assert 'Restoring the previous stable R2 pointer' in s; assert 'published_versioned_manifest' in s\""

[[checks]]
cmd = "git diff --check"
```

## Authority and limits

- GitHub upstream remains the version authority. The workflow resolves official
  Desktop metadata and stable Codex++ Release assets, verifies exact byte size
  and SHA-256, and uploads the original bytes without repackaging. Microsoft
  Store may return HTTP CDN URLs; the workflow permits HTTP only for the exact
  `*.dl.delivery.mp.microsoft.com` host and still requires the MSIX identity,
  resolved version, publisher certificate, and Authenticode chain before
  publication. The current
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
- The workflow does not create a disposable GitHub Release for the verified
  Windows package. The short-lived Actions artifact is only an internal
  hand-off between the Windows resolver and the R2 publisher; R2 is the sole
  public artifact transport and the repository token remains contents-read.
- Repeated-release checks use the bounded `VERIFY_PARALLELISM` worker pool, and
  changed-release uploads reuse the size/SHA-256 computed while splitting each
  part. The optimization changes local runner work only; the healthy fast path
  keeps its bounded HEAD checks, while a repair path may inspect all remaining
  parts before republishing. Public re-download remains the final integrity
  guard, and no integrity gate is skipped.
- Codex++'s three independent upstream assets are downloaded and hashed in
  bounded three-way child jobs, then combined only after every child succeeds.
  Each child still enforces the exact release URL, size, and SHA-256 digest.
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
  and verify the Windows MSIX package identity, resolved version, and its
  Authenticode chain
  before any R2 upload.
- CHG-R2-WF-003: remove the redundant GitHub Release staging upload and disable
  compression for the already-compressed MSIX Actions hand-off, reducing
  transfer time and preserving a contents-read workflow boundary.
- CHG-R2-PUB-003: parallelize unchanged-part metadata checks within the existing
  verification limit and pass split-part size/digest sidecars to upload workers,
  avoiding duplicate local copies and hashes without changing uploaded bytes.
- CHG-R2-WF-004: download and hash the three Codex++ targets concurrently with
  explicit child-job waits, while preserving exact URL, size, digest, and
  post-publish verification gates.
- CHG-R2-SEC-001: run GitHub's Node 24 action majors and verify the exact
  SHA-256 of the PowerShell Gallery resolver before evaluating its functions;
  scope the FE3 certificate workaround to that pinned metadata call only.
- CHG-R2-PUB-004: verify the newly uploaded versioned manifest through its
  public URL before switching the mutable stable pointer; verify the stable
  read after switching and attempt restoration of the prior pointer on failure.
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
- CHK-R2-004: workflow contains no GitHub Release staging job and uses
  `compression-level: 0` for the MSIX hand-off.
- CHK-R2-005: publisher syntax and static assertions prove bounded parallel
  unchanged-part checks, same-filesystem part moves, and sidecar size/digest
  arguments to upload workers.
- CHK-R2-006: workflow syntax/static checks prove three Codex++ child jobs are
  awaited before the combined asset specification is written.
