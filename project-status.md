# LFS262 - Implementing DevSecOps — Project Status

## Course
LFS262 - Implementing DevSecOps (Linux Foundation)

## Environment

* Local machine: MacBook with Apple Silicon (ARM64)
* Cloud: GCP project still deleted — **Lab 8 completed entirely on local `kind` cluster instead**, no GCP dependency needed
* Local tools: kubectl, helm, gcloud SDK, Docker, **kind (v0.32.0)**, **argocd CLI (v3.4.5, arm64 native)**, **watch**
* Local cluster: `kind` cluster named `dso-demo`, single control-plane node, config at `~/code/learning/impl-devsec-ops/kind-config.yaml` (port mappings: `32100`→ArgoCD, `30080`→dso-demo app)
* Repository: `https://github.com/Konstantin-Zhukov/dso-demo`
* Docker Hub: `kostetych/dso-demo` (tags: `multistage`, `latest`, and per-build-number tags from Kaniko, e.g. `:3`)
* Local path: `~/code/learning/impl-devsec-ops/dso-demo`

## Lab 3 - GKE Cluster (COMPLETED — historical, GCP project since deleted)

* Created GKE cluster `cluster-1` in `europe-west2-c`, 4x `e2-standard-2` nodes
* Installed kubectl v1.36.0, configured firewall rules for NodePort access

## Lab 4 - CI Pipeline (COMPLETED — historical on GKE, reinstalled fresh on kind for Lab 8)

* Jenkins on Kubernetes via Helm, `ci` namespace, `jenkins.values.yaml`
* Blue Ocean, Configuration as Code plugins
* Forked/connected `dso-demo` repo, GitHub polling, Kaniko for image build/push

## Lab 5 - SCA (COMPLETED)

* OWASP Dependency Checker (SCA stage) — **known issue, still unresolved**: fails on NVD API 403 (old plugin version 6.1.1 hardcoded), wrapped in `catchError` so it doesn't block the pipeline
* OSS License Checker stage (license_finder)
* Generate SBOM stage (CycloneDX)
* Dependency Track installed then uninstalled to save resources; SBOM successfully sent while it was up

## Lab 6 - SAST (COMPLETED — with tooling change)

* Original: `shiftleft/sast-scan:v2.1.2` — **replaced with Semgrep** (`semgrep/semgrep:latest`) because shiftleft/sast-scan has no arm64 manifest at all (`no match for platform in manifest`), a hard incompatibility on Apple Silicon `kind`, not just an emulation slowdown
* Semgrep stage: `--config=auto`, outputs SARIF + JSON to `reports/`, currently `|| true` (reports but doesn't block)
* Spring Boot updated `2.4.3` → `3.2.2`; Maven image updated to `maven:3.9-eclipse-temurin-17` (Java 17)
* `failBuildOnCVSS=8` added to pom.xml

## Lab 7 - Container Image Auditing (COMPLETED locally, manual)

* Dockle scan — found root user, no healthcheck (original image)
* Trivy scan — 534 vulnerabilities (original) → 64 vulnerabilities after hardening (88% reduction)
* Dockerfile improvements: multi-stage build (maven → amazoncorretto:17-alpine), non-root `devops` user, HEALTHCHECK, CMD as JSON array
* Pushed `kostetych/dso-demo:multistage` to Docker Hub manually
* Automated "Image Analysis" Jenkins stage (Trivy/Dockle in-pipeline) — **not yet added to Jenkinsfile**, still a gap

## Lab 8 - Secure Deployment and DAST (MOSTLY COMPLETED — on local kind, not GKE)

### ArgoCD
* Installed via `kubectl apply --server-side` (server-side apply required — client-side apply hit a 262144-byte annotation limit on the `applicationsets.argoproj.io` CRD)
* Admin password reset to `devSec0ps` (required both `argocd-secret` patch AND `argocd-server` + `argocd-redis` deployment restarts to take effect on v3.4.5)
* Exposed via NodePort `32100`, reachable at `https://localhost:32100` (kind port mapping, not a node IP)
* `devsecops` project created, wildcarded (`*`) on Source Repos / Destinations / Cluster Resource Allow List
* `dso-demo` Application created, manual sync policy, source path `deploy/`, destination namespace `dev`
* App successfully deployed and running (`Synced`/`Healthy`)
* `jenkins` ArgoCD account created with `apiKey` capability
* RBAC policy applied (`role:deployer` — get/sync applications, get projects; delete explicitly denied and confirmed via `rbac can`)
* API token generated and stored in Jenkins as `argocd-jenkins-deployer-token`

### Jenkins (reinstalled fresh on kind, in `ci` namespace)
* Helm install using existing `jenkins.values.yaml` (found at `~/code/learning/impl-devsec-ops/jenkins.values.yaml` — no fixed NodePort, so accessed via `kubectl port-forward -n ci svc/jenkins 8080:8080` instead)
* Blue Ocean + Configuration as Code plugins confirmed pre-installed
* Pipeline job `dso-demo` created (Pipeline script from SCM, Git, `*/main`, `Jenkinsfile`)
* Credentials added: `argocd-jenkins-deployer-token` (secret text), `dockerhub-creds` (username/password, Docker Hub access token)

### build-agent.yaml — significant rework for ARM64/kind
* Added `argocd-cli` container (`schoolofdevops/argocd-cli`) — avoids Docker-in-Docker entirely (kind nodes run containerd, not Docker daemon, so the original `docker-tools` hostPath `/var/run` socket mount doesn't work)
* Added `kaniko` container (`gcr.io/kaniko-project/executor:debug`) for daemonless image builds
* **Removed `slscan`** — see Lab 6 note above
* **Added `semgrep`** as SAST replacement
* `docker-tools` container left in place but currently unused by any active stage; its hostPath docker socket mount won't work on kind if reintroduced later

### Jenkinsfile — new/changed stages
* `SAST` stage rewritten for Semgrep
* `Deploy to Dev` stage switched from `docker run schoolofdevops/argocd-cli` (docker-tools, broken on kind) to native `container('argocd-cli')` calls
* `ARGO_SERVER` set to in-cluster DNS (`argocd-server.argocd.svc.cluster.local`) rather than NodePort/localhost
* **New `Docker Build and Push` stage** added (Kaniko) — builds from `Dockerfile`, pushes `kostetych/dso-demo:${BUILD_NUMBER}` and `:latest` — confirmed working, verified via `docker pull`
* `OSS License Checker` wrapped in `catchError(buildResult: 'SUCCESS', stageResult: 'FAILURE')` after license_finder flagged 4 dependencies needing manual license approval (jakarta.annotation-api, jakarta.xml.bind-api, logback-classic, logback-core) — reports red but doesn't block pipeline; proper fix (license_finder approvals + `dependency_decisions.yml`) deferred
* `SCA` stage's existing `catchError` wrapper confirmed still working as designed

### Full pipeline run achieved — end-to-end SUCCESS
```
Start → Build → Static Analysis (SBOM ✓, License Checker ✗ caught, SCA ✗ caught, Unit Tests ✓)
→ SAST ✓ (Semgrep) → Package ✓ → Docker Build and Push ✓ (Kaniko, verified pull)
→ Deploy to Dev ✓ (ArgoCD sync via in-cluster DNS) → End
```

## Known Gaps / Next Steps

**1. GitOps loop not fully closed:** `deploy/dso-demo-deploy.yaml` still hardcodes `image: kostetych/dso-demo:multistage`. Kaniko pushes a fresh `:${BUILD_NUMBER}` tag every run, but nothing updates the manifest to reference it — `Deploy to Dev` currently re-syncs the same old image every time (confirmed via `deployment.apps/dso-demo unchanged`). To close this:
   1. Create GitHub PAT (repo scope) → add as Jenkins credential `github-pat`
   2. Add `Update Deploy Manifest` stage (sed-replace image tag in `deploy/dso-demo-deploy.yaml`, `git commit`, `git push` using the PAT) between `Docker Build and Push` and `Deploy to Dev`
   3. Verify a full loop: code change → new image built → manifest updated → ArgoCD detects Git diff → new pod deployed

**2. DAST/OWASP ZAP stage** — last remaining piece of Lab 8, not yet added. Plan:
   * Use in-cluster DNS (`http://dso-demo.dev.svc.cluster.local:8080/`) rather than NodePort, consistent with the ARGO_SERVER approach
   * Check `owasp/zap2docker-stable` for arm64 manifest availability before wiring it in — same lesson learned from `shiftleft/sast-scan`; may need a multi-arch ZAP image substitute

**3. Lab 7 Image Analysis stage** — Trivy/Dockle scanning still not automated in Jenkinsfile, only done manually so far. Needs native containers in build-agent.yaml (not docker-tools/socket-based) given the kind/containerd constraint discovered in Lab 8.

**4. License approvals (Option A, deferred)** — currently `OSS License Checker` is caught-and-ignored. Proper fix: run `license_finder approvals add ...` inside the `licensefinder` container (or as a Jenkinsfile step) to generate `dependency_decisions.yml`, commit it, and let the gate mean something again.

**5. NVD 403 (SCA)** — long-standing, still unresolved. Old dependency-check-maven plugin version (6.1.1) hardcoded in pom.xml; newer versions support an NVD API key which would resolve the 403. Not blocking, just always-red.

## Environment Wind-Down

* `kind delete cluster --name dso-demo` — removes ArgoCD, Jenkins, app, everything in one shot
* All config files preserved locally for a quick rebuild later:
  * `~/code/learning/impl-devsec-ops/kind-config.yaml`
  * `~/code/learning/impl-devsec-ops/jenkins.values.yaml`
  * `~/code/learning/impl-devsec-ops/jenkins.argorbacpolicy.csv`
  * `~/code/learning/impl-devsec-ops/argocd_create_user-patch.yaml`
  * `~/code/learning/impl-devsec-ops/argocd_user_rbac-patch.yaml`
* To resume: `kind create cluster --name dso-demo --config kind-config.yaml`, then redo ArgoCD install + password reset, Jenkins Helm install, RBAC patches, and Jenkins credentials (tokens/secrets don't survive a cluster deletion — they'll need regenerating).
