# Codex Desktop and Codex++ Gitee sync Contract

```toml
goal = "从官方上游 Release/Store 元数据同步未修改的 Codex Desktop 安装包与 Codex++ 到两个 Gitee 仓库，并发布可供 Z8 Launch 校验的 latest.json"
base = "e6d9a1e"

[scope]
allow = [
  ".github/workflows/sync.yml",
  "scripts/publish-gitee-mirror.sh",
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
- Codex Desktop is published to `z8hk/codex-mirror`; files are split into
  bounded Base64 parts, uploaded in parallel, downloaded back from Gitee, and
  described by a schema 3 `latest.json` only after every hash check passes.
- The workflow requires the owner-provided `GITEE_TOKEN` secret but never prints or stores it in the repository.
- Quark is out of scope. No upload to cloud drives or private server is performed.
