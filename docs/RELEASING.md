# Release preparation and maintainer checklist

**Proposed version: v3.0.0. Status: unpublished; no release tag or publication is authorized by this preparation.**

The last published GitHub release and Git tag are `v2.0.1` (2024-10-23). At preparation time, `master` was `5aee2b9d2746fd46a2a792897962e3d185316e1c` (interpolation, PR #6). [CHANGELOG.md](../CHANGELOG.md) contains proposed release notes and migration steps for all changes since that tag. Version 3 is proposed because the accumulated controller/deployment changes, stricter validation, new defaults, and default-enabled interpolation alter existing operation. There is no package version file to bump.

## Review before publication

- [ ] Review and merge the preparation PR through the normal maintainer process. This document does not authorize merge or publication.
- [ ] Select the final release commit from reviewed `master`; record its **full SHA** in the release notes/checklist. Refresh the history comparison if more changes land.
- [ ] Confirm `v3.0.0` remains unused, review the changelog, rename the Unreleased heading with the actual publication date, and synchronize release status in both READMEs. Commit those final documentation changes before selecting the tag target.
- [ ] Confirm mocked tests, offline validation, Compose validation, and the default Docker build pass at the exact release commit. Keep logs/CI links:

  ```bash
  git status --short
  git log --oneline v2.0.1..HEAD
  make test
  make validate-example
  # In a disposable checkout only; never overwrite a deployment .env:
  cp .env.example .env
  chmod 600 .env
  docker compose config --quiet
  make docker-build
  git diff --check
  ```

- [ ] Review interpolation migration (`FAN_SPEED_INTERPOLATION=false` for stepwise control), old/new threshold defaults, placeholder validation, explicit image selection, source dependencies and mappings, log persistence, and protected config backups.
- [ ] Record the hardware verification actually performed, with model/firmware and results, or explicitly state none was performed. Historical evidence covers only one R730xd/iDRAC 8; do not claim a supported firmware range. Keep hardware/services unchanged during software-only release preparation.
- [ ] Confirm exit restoration is described as best-effort and the manual stop/restore procedure is available. A healthy log is not evidence of safe cooling.
- [ ] Confirm CodeRabbit App access/OSS eligibility and check actual PR review evidence. Record any activation blocker instead of claiming reviews work from configuration alone. CodeRabbit does not replace maintainer review or hardware validation.
- [ ] Prepare the final release body from the v3.0.0 changelog section, including migration notes, exact target SHA, verification evidence/limits, and rollback instructions. Review it as a local Markdown file before publishing.

## Publication boundary — separate maintainer action

The existing workflow publishes images on **every push to `master` and every `v*` tag**. Pushing a tag is already a publication action; a draft GitHub release is not a safeguard against it. PRs run a non-publishing build. Do not push a tag just to test this workflow.

After a maintainer separately approves publication and checks the selected SHA:

1. Fetch `origin/master` and tags, ensure a clean checkout, and select the reviewed release commit. Check it contains the final workflow and documentation. Confirm the remote tag does not exist:

   ```bash
   git fetch origin master --tags
   git rev-parse HEAD
   git ls-remote --tags origin refs/tags/v3.0.0
   ```

2. Create an annotated `v3.0.0` tag at that exact approved commit and push **only that tag**. This immediately triggers the Docker publication job. Do not run these until publication approval:

   ```bash
   release_commit=REPLACE_WITH_APPROVED_FULL_SHA
   git tag -a v3.0.0 "$release_commit" -m "Release v3.0.0"
   git push origin refs/tags/v3.0.0
   ```

3. Confirm the tag workflow succeeds. It publishes `ghcr.io/df-wu/idrac-fan-control:3.0.0`, `:3.0`, and a `:sha-<short-sha>` tag. The `v` prefix is removed from semver image tags; there is no configured major-only `:3` tag. `latest` tracks default-branch pushes and is **not** updated by the tag event. Verify version labels and record the immutable image digest:

   ```bash
   docker buildx imagetools inspect ghcr.io/df-wu/idrac-fan-control:3.0.0
   ```

4. Publish the GitHub release using the reviewed local notes and existing tag, after image verification. GitHub release publication is a separate step; the image workflow does not create it. For example, with a reviewed local `release-notes-v3.0.0.md`:

   ```bash
   gh release create v3.0.0 --repo DF-wu/iDRACFanSpeedControl \
     --verify-tag --title 'v3.0.0' --notes-file release-notes-v3.0.0.md
   ```

5. Check the public release notes, source archives, image tags/digest, and README links. Record any failed publication step; do not move a published tag silently. If a rebuild is required, agree on a new patch release.

## Rollback

Keep the previous known-good image digest and matching code/configuration. Stop the controller, explicitly restore Dell firmware control, restore the saved deployment/image/config, validate and diagnose, then supervise restart. See the complete [upgrade and rollback procedure](../USAGE_GUIDE.md#upgrade-and-rollback). Do not assume checking out an older Git tag changes the Compose image, and do not recommend v2.0.1 as a universal safe rollback target: its controller and deployment differ substantially.

Publication remains pending maintainer action. This checklist does not deploy a service, touch iDRAC, or certify hardware.
