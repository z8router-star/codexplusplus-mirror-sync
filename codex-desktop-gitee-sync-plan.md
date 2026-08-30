# Codex Desktop and Codex++ domestic mirror sync Contract

> Historical contract. The active R2-only contract is
> `codex-desktop-r2-sync-plan.md`; the Gitee pointer path described below is
> retired because both Gitee repositories are private.

> Do not re-enable this workflow or publisher as part of normal operation.
> Cloudflare R2 is the sole active public transport; this file is retained only
> to preserve the earlier provider evidence and rollback context.

```toml
goal = "[Historical] 从官方上游同步未修改的 Codex Desktop 安装包与 Codex++，并记录已退役的 Gitee 指针方案"
base = "df8f4f3"

[scope]
allow = [
  ".github/workflows/sync.yml",
  "scripts/publish-gitee-mirror.sh",
  "scripts/publish-r2-mirror.sh",
  "scripts/resolve-codex-msix.ps1",
  "codex-desktop-gitee-sync-plan.md",
]
deny = [
  ".env",
  "**/*token*",
  "**/*.key",
  "**/*.pem",
]

[[checks]]
cmd = "python -c \"import pathlib,yaml; yaml.safe_load(pathlib.Path('.github/workflows/sync.yml').read_text(encoding='utf-8'))\""

[[checks]]
cmd = "git diff --check"
```

## Authority and limits

- GitHub's `openai/codex` repository remains the code/version authority, but its
  Release assets are CLI artifacts and are never mirrored as Desktop installers.
  The workflow resolves Desktop bytes from the official OpenAI page,
  Microsoft Store/FE3, and OpenAI's persistent macOS endpoints, verifies their
  identity, size, and SHA-256, and uploads the original bytes without
  repackaging.
- Codex++ remains sourced from `BigPizzaV3/CodexPlusPlus` stable Releases and is published to `z8hk/codexplusplus-mirror`.
- The former implementation published bounded raw identity parts to
  Cloudflare R2 and a small `latest.json` pointer to Gitee. That transport is
  superseded by the R2-only workflow in `codex-desktop-r2-sync-plan.md`; the
  old Gitee Base64 attachment path is disabled and must not be treated as a
  fallback.
- The former workflow required owner-managed Gitee/R2 credentials. They are
  historical evidence only; the active workflow requires only the R2 settings
  documented in `codex-desktop-r2-sync-plan.md`.
- Quark is out of scope. No upload to cloud drives or private server is performed.
