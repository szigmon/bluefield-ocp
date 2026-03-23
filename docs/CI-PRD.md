# DPF BlueField CI/CD PRD
## Product Requirements Document - BlueField OCP + Kernel Modules Build & Release

**Project**: DPF (DPU Platform Framework) Build, Sign & Release
**Author**: Edge Infrastructure Team
**Date**: 2026-03-22
**Status**: Draft
**Stakeholders**: See Section 9 (Team & Responsibilities)

---

## 1. Executive Summary

This PRD defines the CI/CD strategy for building, signing, and releasing all BlueField DPU artifacts through Red Hat's internal Konflux instance. This covers **three workstreams** that need to be coordinated:

| # | Workstream | Status | Owner |
|---|-----------|--------|-------|
| 1 | **bluefield-ocp container image** | Starting | You (this PRD) |
| 2 | **BlueField SOC kernel modules** | ~90% (B&S pipeline exists) | Harel |
| 3 | **OFED kernel modules** | ~50% (code gen exists) | Fabien |

### What Changed
- **BFB images are NO LONGER built here** - merged upstream into CoreOS
- The `bluefield-ocp` repo now focuses on the **container image** that ships the DOCA+OFED stack on RHCOS
- Kernel modules (SOC + OFED) are built separately in `bluefield-kmod-artifacts` and `nvidia-bluefield-kmod-source`
- Dev images -> `quay.io/edge-infrastructure/bluefield-ocp`
- Production images -> `registry.redhat.io` (GA release)

### Current State
- **bluefield-ocp repo**: `https://github.com/rh-ecosystem-edge/bluefield-ocp` (public GitHub)
- Stale `.tekton/` pipelines from old `rhcos-bfb-builder` repo (wrong namespace, wrong branch, wrong component names)
- Existing namespace `rh-ecosystem-tenant` on **public** Konflux (need **internal**)
- SOC drivers build+sign pipeline works on DOCA 3.1.0 (OCP 4.20) and 3.2.1 (OCP 4.21)
- OFED source code generator exists but needs automation pipeline
- **No RPM pipeline** for either SOC or OFED yet

### Target State
- Internal Konflux (`stone-prod-p02`) for all builds
- Automated container image build per OCP release
- Dev images in `quay.io/edge-infrastructure/bluefield-ocp`
- Production images in `registry.redhat.io`
- Signed kernel modules fed into the container build
- Version-controlled build matrix (OCP version x DOCA version)

---

## 2. Ecosystem Map

```
                    UPSTREAM SOURCES
                    ================
    linux.mellanox.com/public/repo/doca/<VERSION>/
    ├── SOURCES/SoC/          ──────┐
    │   └── *.src.rpm               │
    └── <distro>/arm64-dpu/   ──┐   │
        └── RPMs                │   │
                                │   │
    KERNEL MODULE PIPELINES     │   │
    =======================     │   │
                                │   │
    nvidia-bluefield-kmod-source│   │ (gitlab.cee.redhat.com)
    ├── Discovers new DOCA vers.│   │
    ├── Downloads SRPMs ────────┼───┘
    ├── Extracts source code    │
    └── Creates version branches│
              │                 │
              v                 │
    bluefield-kmod-artifacts    │ (gitlab.cee.redhat.com)
    ├── Builds .ko modules      │
    ├── Signs with Red Hat key  │
    ├── Packages as RPMs        │
    └── Uploads to S3 + repo    │
              │                 │
              v                 │
    CONTAINER IMAGE PIPELINE    │
    ========================    │
                                │
    bluefield-ocp (this repo)   │ (github.com, public)
    ├── rhcos-bfb.Containerfile │
    │   ├── Stage 1: BUILDER    │
    │   │   └── Compiles OFED from DOCA sources
    │   └── Stage 2: BASE       │
    │       ├── Installs OFED RPMs from builder
    │       ├── Installs DOCA RPMs ─────────┘ (from DOCA repo)
    │       ├── Installs signed SOC kmod RPMs (from S3/repo)
    │       ├── Installs BF firmware
    │       └── ostree commit
    └── Output: Container image
              │
              ├── Dev:  quay.io/edge-infrastructure/bluefield-ocp
              └── Prod: registry.redhat.io (via release pipeline)
```

---

## 3. Architecture Decisions

### 3.1 Konflux Instance: Internal (`stone-prod-p02`)

**Rationale**:
- Build requires `d-doca-baseurl-auth-creds` to access private DOCA RPM repo (`rpms.okoyl.xyz`)
- Signed kmod RPMs come from internal infrastructure (S3/GitLab)
- Need VPN access for Red Hat internal services
- Internal Konflux can build from approved GitHub orgs AND internal GitLab

**Cluster Details**:
| Property | Value |
|----------|-------|
| UI | `https://konflux-ui.apps.stone-prod-p02.hjvn.p1.openshiftapps.com` |
| API | `https://api.stone-prod-p02.hjvn.p1.openshiftapps.com:6443/` |
| GitHub App | `https://github.com/apps/konflux-internal-p02` |
| Architectures | arm64, amd64, ppc64le, s390x |
| Access | VPN required |

### 3.2 Git Strategy

**Two-track approach**:

| Repo | Host | Konflux Access | Strategy |
|------|------|----------------|----------|
| `bluefield-ocp` | GitHub (public) | Direct via GitHub App OR GitLab mirror | Option A or B below |
| `nvidia-bluefield-kmod-source` | GitLab (internal) | Direct via SCM secret | Native GitLab support |
| `bluefield-kmod-artifacts` | GitLab (internal) | Direct via SCM secret | Native GitLab support |

**Option A (Preferred): Direct GitHub**
- Confirm `rh-ecosystem-edge` org is on `stone-prod-p02` approved list
- Install `konflux-internal-p02` GitHub App on the repo
- Simplest path

**Option B (Fallback): GitLab Mirror with Git Submodule**
- Create `gitlab.cee.redhat.com/partner-accelerators/bluefield-ocp`
- Add GitHub repo as git submodule
- Build from GitLab; MintMaker keeps submodule in sync
- Use when GitHub org is NOT on the approved list

### 3.3 Image Registry Strategy

| Stage | Registry | Image Path | Purpose |
|-------|----------|------------|---------|
| Build (Konflux-managed) | quay.io | `quay.io/redhat-user-workloads/<tenant>/bluefield-ocp/...` | Intermediate build artifacts |
| Developer Release | quay.io | `quay.io/edge-infrastructure/bluefield-ocp` | Dev/test consumption |
| Production Release | registry.redhat.io | TBD (via managed release pipeline) | GA customer release |

### 3.4 Version Matrix

Each OCP+DOCA combination = one Konflux Component on its own branch:

| Branch | OCP | DOCA | SOC Kmod | OFED | Component Name |
|--------|-----|------|----------|------|----------------|
| `4.21.x-DOCA-3.3` | 4.21 | 3.3 | 3.3.0 | from DOCA 3.3 | `bluefield-ocp-421-doca33` |
| `4.20.x-DOCA-3.1` | 4.20 | 3.1 | 3.1.0 | from DOCA 3.1 | `bluefield-ocp-420-doca31` |

---

## 4. Secrets & Credentials

| Secret Name | Type | Purpose | Who Creates | Scope |
|-------------|------|---------|-------------|-------|
| `d-doca-baseurl-auth-creds` | Key/Value (`username-and-password`) | Private DOCA RPM repo auth | You | Build (`ADDITIONAL_SECRET`) |
| Registry pull secret (`registry.redhat.io`) | Image Pull | Pull OCP release images | You | Build |
| Registry push secret (`quay.io/edge-infrastructure`) | Image Push | Push dev images | You | Release |
| GitLab access token (if Option B) | SCM (`kubernetes.io/basic-auth`) | GitLab repo access for PaC | You | Component onboarding |
| `snyk-secret` (optional) | Key/Value (`snyk_token`) | SAST scanning | You | Build |
| Signing key secret | Managed by releng | Image signing for `registry.redhat.io` | Release Engineering | Production release |

---

## 5. Milestones & Tasks

### Phase A: This Repo (bluefield-ocp container image)

#### Milestone 0: Access & Prerequisites [0/6]
> **Goal**: Get internal Konflux access, choose git strategy
> **Blocked by**: Nothing
> **Can be done by**: You

- [ ] **M0.1**: Request tenant namespace on `stone-prod-p02`
  - Use Konflux onboarding process (see internal docs "Create a tenant Namespace")
  - Test: `oc login --web https://api.stone-prod-p02.hjvn.p1.openshiftapps.com:6443/` succeeds
- [ ] **M0.2**: Check if `rh-ecosystem-edge` GitHub org is approved for `stone-prod-p02`
  - Ask in `#konflux-users` Slack via "Ask for support" workflow
  - Test: Get confirmation from releng team
- [ ] **M0.3**: (If approved) Install `konflux-internal-p02` GitHub App on `bluefield-ocp` repo
  - Go to `https://github.com/apps/konflux-internal-p02` and install on repo
  - Test: GitHub Settings > Installed Apps shows the Konflux app
- [ ] **M0.4**: (If NOT approved) Create internal GitLab mirror repo
  - Create `gitlab.cee.redhat.com/partner-accelerators/bluefield-ocp`
  - Add GitHub public repo as git submodule
  - Test: `git clone --recursive` pulls full content
- [ ] **M0.5**: Get DOCA repo credentials from team
  - Format: `username:password` for `rpms.okoyl.xyz`
  - Test: `curl -u user:pass https://rpms.okoyl.xyz/repo/doca/` returns 200
- [ ] **M0.6**: Identify/create quay.io org `edge-infrastructure` and robot account
  - Create robot account with write access to `bluefield-ocp` repo
  - Test: `podman login quay.io/edge-infrastructure` succeeds

---

#### Milestone 1: First Build [0/8]
> **Goal**: Get one branch building successfully in Konflux
> **Blocked by**: M0 complete
> **Can be done by**: You

- [ ] **M1.1**: Create Konflux Application `bluefield-ocp` (via UI or CLI)
  - Test: `kubectl get application bluefield-ocp` returns resource

- [ ] **M1.2**: Create Component for branch `4.21.x-DOCA-3.3`
  - Pipeline: `docker-build-multi-platform-oci-ta`
  - Dockerfile: `rhcos-bfb.Containerfile`
  - Revision: `4.21.x-DOCA-3.3`
  - Test: `kubectl get component bluefield-ocp-421-doca33` shows `True`

- [ ] **M1.3**: Create ImageRepository for the component
  - Visibility: `public`
  - Test: ImageRepository shows image URL in status

- [ ] **M1.4**: Create `d-doca-baseurl-auth-creds` secret
  ```bash
  kubectl create secret generic d-doca-baseurl-auth-creds \
    --from-literal=username-and-password='<user>:<password>' \
    -n <tenant-namespace>
  ```
  - Link to component service account
  - Test: `kubectl get secret d-doca-baseurl-auth-creds` exists

- [ ] **M1.5**: Create registry pull secret for `registry.redhat.io` and `quay.io/openshift-release-dev`
  - Test: Build can pull base images

- [ ] **M1.6**: Review and merge Konflux-generated onboarding PR
  - Konflux will PR new `.tekton/` files to the repo
  - Test: PR appears with pipeline YAML files

- [ ] **M1.7**: Customize `.tekton/` pipeline files:
  - `build-platforms: [linux/arm64]`
  - `dockerfile: rhcos-bfb.Containerfile`
  - `build-args-file: argfile.conf`
  - `ADDITIONAL_SECRET: d-doca-baseurl-auth-creds`
  - Timeouts: `pipeline: 6h`, `tasks: 3h`, `finally: 3h`
  - `on-cel-expression`: target `4.21.x-DOCA-3.3`
  - `submodules: "true"` on git-clone task
  - Test: Commit to branch triggers pipeline

- [ ] **M1.8**: Verify first successful build
  - Test: Green pipeline in Konflux UI, image appears in quay

---

#### Milestone 2: Pipeline Hardening [0/6]
> **Goal**: Production-quality pipeline with proper tags, labels, path filtering
> **Blocked by**: M1 complete
> **Can be done by**: You

- [ ] **M2.1**: Centralize pipeline into `.tekton/build-pipeline.yaml`
  - PR and push PipelineRuns both reference shared Pipeline via `pipelineRef`
  - Test: Both triggers use same pipeline definition

- [ ] **M2.2**: Add image tags (branch + commit-based)
  - `ADDITIONAL_TAGS: ["{{target_branch}}", "{{target_branch}}-{{revision}}"]`
  - Test: `skopeo inspect` shows custom tags

- [ ] **M2.3**: Add OCI labels
  - `rhcos.version`, `rhcos.doca.version`, `org.opencontainers.image.version`
  - Test: `skopeo inspect` shows custom labels

- [ ] **M2.4**: Path-based triggering (skip on README-only changes)
  - Filter on `rhcos-bfb.Containerfile`, `argfile.conf`, `assets/`, `patches/`, `.tekton/`
  - Test: Editing `readme.md` does NOT trigger build

- [ ] **M2.5**: PR image expiration (`image-expires-after: 5d`)
  - Test: PR images have expiration; push images don't

- [ ] **M2.6**: Verify git submodules clone correctly
  - `bfb/bfscripts`, `bfb/bfb-build`, `custom-coreos-disk-images`
  - Test: Build accesses files from submodule directories

---

#### Milestone 3: Security & Compliance [0/5]
> **Goal**: Pass Conforma (Enterprise Contract) checks
> **Blocked by**: M1 complete (can parallel with M2)
> **Can be done by**: You + may need releng help for EC exceptions

- [ ] **M3.1**: Verify Conforma integration test exists
  - Test: `kubectl get integrationtestscenario` shows EC test for app

- [ ] **M3.2**: Run push build and review EC results
  - Test: Integration pipeline runs after build

- [ ] **M3.3**: Address EC violations
  - Likely issues: unsigned DOCA RPMs, deprecated base images
  - May need EC policy exception request
  - **Need help from**: Release Engineering for policy customization
  - Test: EC passes or has approved exceptions

- [ ] **M3.4**: Set up Snyk SAST scanning (optional)
  - Test: `sast-snyk-check` runs

- [ ] **M3.5**: Review SBOM output
  - Test: `cosign download sbom <image>` produces valid CycloneDX

---

#### Milestone 4: Release Pipeline [0/7]
> **Goal**: Automated release to dev quay + production registry
> **Blocked by**: M3 (EC must pass)
> **Can be done by**: You + Release Engineering team

- [ ] **M4.1**: Set up quay.io push secret for `edge-infrastructure` org
  - Test: Secret exists and is linked to SA

- [ ] **M4.2**: Create ReleasePlan for dev releases (quay.io)
  - Auto-release on push build success
  - Target: `quay.io/edge-infrastructure/bluefield-ocp`
  - Test: `kubectl get releaseplan` shows Matched

- [ ] **M4.3**: Create tenant release pipeline
  - Copy image to `quay.io/edge-infrastructure/bluefield-ocp`
  - Tag format: `<ocp-version>-doca<doca-version>-<date>`
  - Test: Release pipeline copies image with correct tags

- [ ] **M4.4**: Test manual release
  - Create Release CR referencing a snapshot
  - Test: Image appears in `quay.io/edge-infrastructure/bluefield-ocp`

- [ ] **M4.5**: Enable auto-release for dev
  - Test: Push -> build -> test -> release happens automatically

- [ ] **M4.6**: **[Needs releng help]** Set up production release to `registry.redhat.io`
  - Requires managed release pipeline (ReleasePlanAdmission)
  - Requires image signing with Red Hat key
  - **Need help from**: Release Engineering team
  - Test: Released image accessible at `registry.redhat.io/...`

- [ ] **M4.7**: Document release process for GA
  - Manual vs automatic release triggers
  - Test: Team can perform a release independently

---

#### Milestone 5: Multi-Version & Maintenance [0/5]
> **Goal**: Support multiple OCP+DOCA branches, automated updates
> **Blocked by**: M1 complete
> **Can be done by**: You

- [ ] **M5.1**: Create Component for `4.20.x-DOCA-3.1` branch
  - Test: Separate pipeline for each branch

- [ ] **M5.2**: Verify branch isolation (no cross-triggering)
  - Test: Push to branch A doesn't trigger branch B

- [ ] **M5.3**: Create `renovate.json` for MintMaker
  ```json
  {
    "$schema": "https://docs.renovatebot.com/renovate-schema.json",
    "extends": ["github>konflux-ci/mintmaker-presets:cve-automerge-critical"],
    "dockerfile": {
      "fileMatch": ["rhcos-bfb\\.Containerfile"]
    }
  }
  ```
  - Test: MintMaker creates PRs for Tekton task updates

- [ ] **M5.4**: Review/merge initial MintMaker PRs
  - Test: Task bundles updated to latest versions

- [ ] **M5.5**: Clean up old `.tekton/` files (remove `rhcos-bfb-builder-e9f5e` references)
  - Test: No stale references remain

---

### Phase B: Kernel Modules (Parallel Workstream)

> These are NOT blocked by Phase A but are **dependencies** for the container image to be complete.
> They involve different repos and different team members.

#### Milestone 6: SOC Kernel Modules [0/4]
> **Owner**: Harel
> **Repo**: `bluefield-kmod-artifacts` (GitLab internal)
> **Status**: ~90% done

- [ ] **M6.1**: SOC drivers building and signing for DOCA 3.1.0 (OCP 4.20)
  - Currently working in B&S pipeline
  - Test: Signed RPMs available in repo/S3

- [ ] **M6.2**: SOC drivers building and signing for DOCA 3.2.1 (OCP 4.21)
  - Currently working in B&S pipeline
  - Test: Signed RPMs available in repo/S3

- [ ] **M6.3**: Add RHEL 9.8 + 10.2 support (if needed for future OCP)
  - Fix compilation failures from kernel ABI changes
  - Test: Modules compile against 9.8 and 10.2 kernels

- [ ] **M6.4**: Create RPM pipeline (currently missing!)
  - **Blocked**: No RPM build pipeline exists yet
  - **Need help from**: Build & Sign team for RPM pipeline setup
  - Test: RPMs are automatically built and published

---

#### Milestone 7: OFED Kernel Modules [0/4]
> **Owner**: Fabien
> **Repo**: `nvidia-bluefield-kmod-source` (GitLab internal)
> **Status**: ~50% done

- [ ] **M7.1**: Validate OFED source code generator works for all target versions
  - Fabien's code generation script
  - Test: Source code generated for DOCA 3.1, 3.2, 3.3

- [ ] **M7.2**: Automate OFED code generation in GitLab CI
  - Extend `.gitlab-ci.yml` to trigger generation + build
  - Test: New DOCA version auto-generates source branches

- [ ] **M7.3**: Build OFED .ko modules from generated source
  - Use `build.sh` from `nvidia-bluefield-kmod-source`
  - Test: `.ko` files compile for target kernels

- [ ] **M7.4**: Create RPM pipeline for OFED (currently missing!)
  - Same blocker as SOC RPM pipeline
  - **Need help from**: Build & Sign team
  - Test: OFED RPMs automatically built and published

---

#### Milestone 8: Integration [0/3]
> **Goal**: Wire kernel module outputs into the container image build
> **Blocked by**: M6+M7 RPM pipelines, M1 (container build working)
> **Can be done by**: You + Harel + Fabien

- [ ] **M8.1**: Make signed SOC kmod RPMs available to Containerfile build
  - Either via DOCA repo URL or as pre-built RPMs in a hosted repo
  - Test: `rhcos-bfb.Containerfile` can `dnf install` signed SOC kmods

- [ ] **M8.2**: Make OFED compiled RPMs available to Containerfile build
  - Currently compiled in builder stage from source
  - Test: OFED RPMs install correctly in container

- [ ] **M8.3**: End-to-end validation
  - Container image with all components builds successfully
  - Image boots on BlueField-3 hardware
  - Test: DPU boots RHCOS with all drivers loaded

---

## 6. Dependencies & Blockers

```
M0 (Access) ──────> M1 (First Build) ──────> M2 (Hardening)
                         │                        │
                         │                   M3 (Security) ──> M4 (Release)
                         │
                         └──────> M5 (Multi-version)

M6 (SOC kmods) ──┐
                  ├──> M8 (Integration)
M7 (OFED kmods) ─┘
```

**Critical blockers to escalate**:
1. **No RPM pipeline** - Neither SOC nor OFED have automated RPM build/publish
2. **GitHub org approval** - Need confirmation from Konflux releng
3. **Production release path** - Need releng involvement for `registry.redhat.io`

---

## 7. Help Needed From Others

| Who | What | When | Priority |
|-----|------|------|----------|
| **Konflux releng** (`#konflux-users`) | Approve `rh-ecosystem-edge` GitHub org for `stone-prod-p02` | M0 | CRITICAL |
| **Konflux releng** | Set up managed release pipeline for `registry.redhat.io` | M4 | HIGH |
| **Build & Sign team** | RPM build pipeline for SOC + OFED kernel modules | M6, M7 | HIGH |
| **Harel** | Confirm SOC kmod RPM availability for DOCA 3.3 | M6 | MEDIUM |
| **Fabien** | Confirm OFED code generator works for all versions | M7 | MEDIUM |
| **CoreOS team** | Confirm BFB generation is fully upstream (no action needed from us) | Informational | LOW |

---

## 8. Variables Reference

### Build Args (`argfile.conf` - per branch)

| Variable | Example (4.21.x-DOCA-3.3) | Description |
|----------|---------------------------|-------------|
| `RHCOS_VERSION` | `4.20.4` | RHCOS version from OCP release |
| `TARGET_IMAGE` | `quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:...` | Base RHCOS image (pinned digest) |
| `BUILDER_IMAGE` | `quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:...` | Builder stage base (pinned digest) |
| `D_ARCH` | `aarch64` | Always aarch64 for BlueField |
| `D_DOCA_VERSION` | `3.1.0` | NVIDIA DOCA version |
| `D_DOCA_DISTRO` | `rhel9.6` | DOCA distribution target |
| `D_DOCA_BASEURL` | `https://rpms.okoyl.xyz/repo/doca/3.1.0/rhcos_4.20.4` | Private DOCA RPM repo |
| `D_DOCA_BASEURL_AUTH` | `true` | Enable auth for repo |
| `IMAGE_TAG` | `tp-latest` | Custom tag |

### Stale Tekton Variables (MUST update)

| Variable | Old (stale) | New (correct) |
|----------|-------------|---------------|
| `namespace` | `rh-ecosystem-tenant` | `<new-tenant>` |
| `application` | `rhcos-bfb-builder` | `bluefield-ocp` |
| `component` | `rhcos-bfb-builder-e9f5e` | `bluefield-ocp-421-doca33` |
| `target_branch` | `master` | `4.21.x-DOCA-3.3` |
| `output-image` | `.../rh-ecosystem-tenant/rhcos-bfb-builder-e9f5e` | `.../bluefield-ocp/bluefield-ocp-421-doca33` |
| `serviceAccountName` | `build-pipeline-rhcos-bfb-builder-e9f5e` | `build-pipeline-bluefield-ocp-421-doca33` |
| `build.appstudio.openshift.io/repo` | `.../rhcos-bfb-builder` | `.../bluefield-ocp` |

---

## 9. Team & Responsibilities

| Person | Role | Workstreams |
|--------|------|-------------|
| **You** | Container image CI/CD lead | M0-M5, M8 |
| **Harel** | SOC kernel module expert | M6 |
| **Fabien** | OFED code generation | M7 |
| **Konflux releng** | Platform support | M0.2, M4.6 |
| **B&S team** | RPM pipeline | M6.4, M7.4 |

---

## 10. Risk Assessment

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| GitHub org not on approved list | Blocks M1 | Medium | Fall back to GitLab mirror (Option B) |
| No RPM pipeline for kmods | Blocks M8 integration | High | Escalate to B&S team; interim: manual RPM builds |
| ARM remote builder unavailable | Build failures | Low | Retry; contact `#forum-konflux-infrastructure` |
| DOCA repo credentials expire | Build failures | Medium | Document rotation; set reminders |
| Unsigned DOCA RPMs fail EC | Release blocked | High | Request EC policy exception |
| Build timeout (>3h ARM) | Pipeline fails | Medium | Already set 3h task timeout; can increase |
| OFED code gen not ready for all versions | Incomplete container | Medium | Fall back to compiling from source in Containerfile (current approach) |
| Production release path unclear | Can't GA | Medium | Engage releng early (M4.6) |

---

## 11. Success Criteria

1. Every push to a version branch triggers a build that produces a signed container image
2. PR builds run security scans and report status back to GitHub
3. Conforma policy passes (with documented exceptions)
4. Dev images auto-publish to `quay.io/edge-infrastructure/bluefield-ocp`
5. Production release path to `registry.redhat.io` is documented and tested
6. Multiple OCP+DOCA version branches build independently
7. Kernel modules (SOC + OFED) are properly signed and included
8. MintMaker keeps Tekton tasks up to date
9. Any team member can perform a release independently

---

## 12. Suggested Kickoff Actions (This Week)

1. **You**: Request Konflux namespace (M0.1) and check org approval (M0.2)
2. **You**: Share this PRD with Harel, Fabien, and the B&S team
3. **You + Harel**: Confirm SOC kmod RPM locations for the Containerfile
4. **You + Fabien**: Status check on OFED code generator readiness
5. **All**: Discuss RPM pipeline gap in team standup - who owns this?
6. **You**: Ask in `#konflux-users` about `registry.redhat.io` release pipeline setup
