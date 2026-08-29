# Codex Desktop and Codex++ domestic mirror sync Contract

```toml
goal = "从官方上游 Release/Store 元数据同步未修改的 Codex Desktop 安装包与 Codex++ 到 Cloudflare R2，并在 Gitee 发布可供 Z8 Launch 校验的 latest.json 指针"
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
- Codex Desktop and Codex++ are published to Cloudflare R2 as bounded raw
  identity parts, downloaded back through the public R2 URL, and described by
  a schema 3 `latest.json` only after every hash check passes. The manifest is
  then written to the corresponding Gitee repository as a small domestic
  pointer. If the R2 variables are absent, the workflow keeps the prior Gitee
  Base64 attachment path available.
- The R2 workflow requires the owner-provided `CLOUDFLARE_ACCOUNT_ID`,
  `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`, and
  `R2_PUBLIC_BASE_URL` values plus the existing `GITEE_TOKEN`; none are printed
  or stored in the repository.
- Quark is out of scope. No upload to cloud drives or private server is performed.
