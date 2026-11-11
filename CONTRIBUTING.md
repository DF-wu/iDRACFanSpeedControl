# Contributing

Keep changes focused and describe actual behavior. Do not test against iDRAC, SSH targets, GPUs, or disks without the hardware owner's explicit authorization. The repository tests use mocks; do not describe those as hardware verification.

## Local checks

With Bash 4+, GNU coreutils, awk, and Make:

```bash
make test
make validate-example
git diff --check
```

With Docker/Compose, in a disposable checkout using only the example configuration:

```bash
cp .env.example .env
chmod 600 .env
docker compose config --quiet
make docker-build
```

The example contains intentionally invalid live-target placeholders. Do not start the Compose service with it. `make validate-example` uses an offline iDRAC-only dry run and does not load `.env`. The Dockerfile build runs shell syntax/help checks without hardware access. `make validate` validates a real root `.env` inside the selected image; it does not send fan commands. Do not print expanded Compose configuration containing actual secrets into CI logs.

CI runs the mocked tests, validates Compose, and builds the image for PRs into `master`; PRs do not log in to GHCR or publish. Only pushes to `master` or `v*` tags publish images. Release preparation is in [docs/RELEASING.md](docs/RELEASING.md).

## Documentation and localization contract

`README.md` is the English reference and `README.zh-TW.md` is its Traditional Chinese localization. Update both in the same PR whenever commands, defaults, warnings, deployment instructions, or supported behavior change. Preserve the language-switch links and equivalent technical content; translate prose while retaining exact command/variable names. New engineering docs, commits, PR descriptions, and review discussions use English. Operations and troubleshooting guides are maintained in English and linked from both READMEs.

Verify relative Markdown links and anchors, shell examples, source/default tables against `src/FanControlWithEsxiSmart.sh`, TUI choices against `src/fan-control-tui.sh`, and deployment instructions against Compose/Dockerfile. Keep `.env`, keys, logs, and incident files out of Git.

## CodeRabbit OSS reviews

This repository prepares review settings for the **CodeRabbit GitHub App** in [`.coderabbit.yaml`](.coderabbit.yaml); installation and operation must be verified separately. The configuration requests English automatic reviews and incremental review on pushes, skips draft PRs, and uses the default target branch (`master`). No token-based review Action or API secret is required.

### Owner enablement

1. Open the [CodeRabbit App installation page](https://github.com/apps/coderabbitai/installations/new), sign in as an owner/admin, and select **DF-wu**.
2. Choose **Only select repositories** and add **iDRACFanSpeedControl**. If CodeRabbit is already installed with selected access, configure that installation and add only this repository, preserving any existing authorized selection. Do not expand access to all repositories. Review the App permissions and finish installation/authorization.
3. Sign in to [CodeRabbit](https://app.coderabbit.ai/) with GitHub, select the DF-wu account, and enable review access for this repository if its repository toggle is off. Keep automatic reviews enabled. Use OSS access; do not add billing, purchase seats, enable usage-based billing, or activate paid products for this setup.
4. Open or mark a PR into `master` ready for review and look for an actual CodeRabbit status/comment/review. Configuration alone does not prove operation. Record the PR head SHA and the review evidence.

[Official pricing](https://docs.coderabbit.ai/management/plans) states that OSS projects receive review features without a paid subscription or credit card. Public repositories below 10 stars currently require a manual trigger; this repository had 10 stars when checked on 2026-11-11. Eligibility and rate limits are service policy, so recheck before claiming ongoing automatic coverage. The general Free plan and an expiring trial are not evidence of permanent OSS review access.

### First PR, drafts, and troubleshooting

The [official YAML guide](https://docs.coderabbit.ai/getting-started/yaml-configuration) says the configuration on the feature branch is used for that PR. The first PR adding `.coderabbit.yaml` can therefore be reviewed before merge, once App access is enabled. With `drafts: false`, keep work in draft until ready, then mark it ready to exercise automatic review. Installation after PR creation may need a one-time manual bootstrap:

```text
@coderabbitai full review
```

For later updates, `@coderabbitai review` requests an incremental review. These commands are an explicit bootstrap/retry, not proof that automatic triggering works. For missing reviews, check App repository selection, the CodeRabbit repository toggle, ready/draft status, target branch, OSS eligibility/rate limits, and the bot's skip reason. `@coderabbitai configuration` shows the resolved settings. The service can pause incremental reviews after its default reviewed-commit limit; use its resume/review controls as needed.

Validate `.coderabbit.yaml` against the [current official schema](https://coderabbit.ai/integrations/schema.v2.json), using the [YAML validator](https://docs.coderabbit.ai/configuration/yaml-validator) or a local JSON Schema validator. See [automatic review controls](https://docs.coderabbit.ai/configuration/auto-review) for branch/draft behavior. Do not make CodeRabbit a required merge check until actual repository evidence confirms it is running reliably.
