![](../assets/img/krar-logo-small.png)

# Kubernetes Resources Auto Rollout aka krar

`krar` is a lightweight, Kubernetes-native shell helper for enforcing rollout policies across your workloads.  
It is designed to run as a **CronJob** and operate on `Deployments`, `DaemonSets`, and `StatefulSets` based on a **label-driven policy**, without requiring application changes.

Its primary use cases are:

1. **Rolling restart on a scheduled basis**  
   Example: Restart workloads on the first day of each month to refresh ephemeral certificates, reduce memory fragmentation, or enforce periodic rollouts.
2. **Image update detection with and without rollout**  
   Detect whether the **tagged image** currently running matches the **registry digest** for the small tag.  
   Detects **mutable tag drift** (e.g., `latest`, `stable`, `1.0.0`) caused by rebuilds, force pushes, or image relocations.

krar works **cluster-local**, is fully stateless, and does not require external services or agents.

---

## Features

Important behavior:

* In rollout or smart mode, only containers with `imagePullPolicy: Always` are considered.
* Containers with `imagePullPolicy: IfNotPresent` (or anything else) are ignored.

This avoids unnecessary rollouts where the image would not be pulled again anyway.

### Rollout mode (default)

* Select workloads based on a label selector, or based on targeted resources
* Retrieve resource manifests automatically
* Trigger:
  `kubectl rollout restart -f resources.yaml`
* Works cluster-wide or in a restricted namespace scope

### Smart mode

Same as Rollout mode, plus:

* Inspect live containers used by matching workloads
* Extract their **current digest** (`imageID`)
* Query the **remote registry** for the **same tag**, fetch its digest
* Compare digests to detect **new builds under the same tag**
* Supports two behaviors:
  * **report-only** (default): do not restart, print drift information
  * **auto-restart** (explicit): restart workloads **only if drift is detected**

This is ideal for clusters using mutable tags such as:

* `latest`
* `stable`
* semantic tags rebuilt over time (`1.0.0` after a fix)

---

## Requirements

krar is a container image that bundles:

* `bash`
* `kubectl`
* `jq`
* `skopeo`

The container only requires:

* Kubernetes API access
* `get`, `list` on `pods`
* `get`, `list`, and `patch` on at least one of those:
  * `deployments`,
  * `statefulsets`,
  * `daemonsets`
* A ServiceAccount (provided by a Helm chart or manually)

No CRDs are required.

---

## Usage Overview

krar can be invoked:

* As a **CronJob** in Kubernetes (most common)
* Manually (local development, debugging)
* Via CLI inside the container

It supports **two modes**:

| Mode          | Description                                                        |
|---------------|--------------------------------------------------------------------|
| `rollout`     | Restart workloads using `kubectl rollout restart`                  |
| `smart`   | Detect and optionally restart when a newer digest exists            |

---

## Private registries & authentication

When running in `smart` mode, krar uses `skopeo inspect` to query image metadata from the registry.  
If your images are stored in **private registries**, you need to provide authentication.

krar supports several mechanisms, evaluated in this order:

1. **Explicit auth file (`config.json`)** via `KRAR_REGISTRY_AUTHFILE`  
2. **Inline credentials** via `KRAR_REGISTRY_CREDS`  
3. **Custom Docker config directory** via `KRAR_DOCKER_CONFIG`  
4. **Default Docker config** (e.g. `~/.docker/config.json`), if available

## Environment Variables

All environment variables can be overridden via CLI flags.  
The fallback order is:


### Core parameters

| Variable              | Description                                                                                                                                                                                                 |
|-----------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `KRAR_RESOURCES`      | Comma-separated resource kinds for label-based discovery (e.g. `deployments,daemonsets,statefulsets`)                                                                                                       |
| `KRAR_LABEL_DOMAIN`   | Label domain (e.g. `krar.slash-mnt.com`)                                                                                                                                                                    |
| `KRAR_LABEL_NAME`     | Label key name (e.g. `rollout-policy`)                                                                                                                                                                      |
| `KRAR_LABEL_VALUE`    | Label value. If unset, the script falls back to `KRAR_JOB_NAME`, then `JOB_NAME`.                                                                                                                           |
| `KRAR_TARGETS`        | Explicit list of targets in addition to label-based discovery. Format: `namespace/Kind/name` entries separated by commas. Example: `default/Deployment/app1,prod/StatefulSet/db,infra/DaemonSet/log-agent`. |
| `KRAR_NAMESPACES_ALL` | `"true"` to target all namespaces for label-based discovery, `"false"` to restrict to `KRAR_NAMESPACES`.                                                                                                    |
| `KRAR_NAMESPACES`     | Comma-separated namespaces used when `KRAR_NAMESPACES_ALL="false"`.                                                                                                                                         |
| `KRAR_DRY_RUN`        | `"true"` to only print actions without calling `kubectl rollout restart`. Affects both modes.                                                                                                               |
| `KRAR_JOB_NAME`       | Optional logical job name used as a fallback for `KRAR_LABEL_VALUE`.                                                                                                                                        |
| `KRAR_MODE`           | Operating mode: `"rollout"` or `"smart"`. Default: `rollout`.                                                                                                                                               |
| `KRAR_SMART_RESTART`  | `"true"` to automatically restart workloads in `smart` mode when drift is detected. Default: `false`.                                                                                                       |


Defaults:

```bash
KRAR_MODE=rollout
KRAR_NAMESPACES_ALL=true
KRAR_DRY_RUN=false
KRAR_LABEL_DOMAIN=krar.slash-mnt.com
KRAR_LABEL_NAME=rollout-policy
```

### Environment variables for registry auth

| Variable                  | Type      | Description                                                                 |
|---------------------------|-----------|-----------------------------------------------------------------------------|
| `KRAR_REGISTRY_AUTHFILE`  | file path | Path to a `config.json` passed to `skopeo` as `--authfile <path>`          |
| `KRAR_REGISTRY_CREDS`     | string    | Credentials as `username:password`, passed to `skopeo` as `--creds`        |
| `KRAR_DOCKER_CONFIG`      | dir path  | Directory containing `config.json`, exported as `DOCKER_CONFIG`            |

**Precedence** for `skopeo inspect`:

1. If `KRAR_REGISTRY_AUTHFILE` is set → `skopeo inspect --authfile "$KRAR_REGISTRY_AUTHFILE" ...`
2. Else if `KRAR_REGISTRY_CREDS` is set → `skopeo inspect --creds "$KRAR_REGISTRY_CREDS" ...`
3. Else if `KRAR_DOCKER_CONFIG` is set → `DOCKER_CONFIG="$KRAR_DOCKER_CONFIG"` (used by `skopeo`)
4. Else → `skopeo` relies on its default mechanisms (e.g. `~/.docker/config.json`)

## CLI Usage

```
docker run --rm slashmnt/krar:<version> \
  --resources "deployments,statefulsets" \
  --label-domain "krar.slash-mnt.com" \
  --label-name "rollout-policy" \
  --label-value "once-a-month"
```

### Explicit targets only (no labels)

```
docker run --rm slashmnt/krar:<version> \
  -n "" -A \
  --mode rollout \
  # using environment
  -e KRAR_TARGETS="default/Deployment/app1,prod/StatefulSet/db"
```

### Show help

```
docker run --rm slashmnt/krar:<version> --help
```

### Examples

#### Force rollout for all label-selected workloads once per month

```
docker run --rm slasmnt/krar:1.0.0 \
  --resources "deployments,daemonsets,statefulsets" \
  --label-domain "krar.slash-mnt.com" \
  --label-name "rollout-policy" \
  --label-value "once-a-month"
```

#### Dry-run: show which workloads will be restarted

```
docker run --rm slashmnt/krar:1.0.0 \
  --resources "deployments" \
  --label-domain "krar.slash-mnt.com" \
  --label-name "rollout-policy" \
  --label-value "nightly" \
  --dry-run
```

#### Smart mode: detect drift without restarting

```
docker run --rm slasmnt/krar:1.0.0 \
  --mode smart \
  --resources "deployments" \
  --label-domain "krar.slash-mnt.com" \
  --label-name "rollout-policy" \
  --label-value "critical"
```

This will:

1. Inspect running Pods
2. Capture imageID digests
3. Query registry via skopeo inspect
4. Compare digests
5. Report if a newer build exists under the same tag

No rollout occurs.

#### Smart mode: detect drift and restart automatically

```
docker run --rm slasmnt/krar:1.0.0 \
  --mode smart \
  --smart-restart \
  --resources "deployments" \
  --label-domain "krar.slash-mnt.com" \
  --label-name "rollout-policy" \
  --label-value "critical"
```

When drift is detected, krar will:

1. Print detailed digest information
2. Trigger kubectl rollout restart on the matching workloads

## Kubernetes deployment

### Helm chart

A Helm chart is directly available at https://github.com/slash-mnt/helm-krar.

### Minimal CronJob example (raw YAML)

`cronjob.yaml`:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: krar-monthly
spec:
  schedule: "0 0 1 * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          serviceAccountName: krar
          containers:
            - name: krar
              image: docker.io/slasmnt/krar:1.0.0
              env:
                - name: KRAR_RESOURCES
                  value: "deployments,daemonsets,statefulsets"
                - name: KRAR_LABEL_DOMAIN
                  value: "krar.slash-mnt.com"
                - name: KRAR_LABEL_NAME
                  value: "rollout-policy"
                - name: KRAR_LABEL_VALUE
                  value: "once-a-month"
                - name: KRAR_MODE
                  value: "smart"
                - name: KRAR_SMART_RESTART
                  value: "true"

```

`rbac.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: krar
rules:
  - apiGroups: ["", "apps"]
    resources: ["deployments", "daemonsets", "statefulsets"]
    verbs: ["get", "list", "patch"]
```

### Example: CronJob with private registry authentication (authfile)

This example shows how to:

- mount a **Docker config.json** stored as a Kubernetes secret
- point krar to it using `KRAR_REGISTRY_AUTHFILE`
- run in `smart` mode with automatic restart on drift

First, create a secret from your Docker config:

```bash
kubectl create secret generic docker-config \
  --from-file=config.json=/path/to/your/config.json
```

Then define the CronJob:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: krar-smart-private
spec:
  schedule: "*/30 * * * *" # every 30 minutes
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          serviceAccountName: krar
          containers:
            - name: krar
              image: docker.io/slasmnt/krar:1.0.0
              env:
                - name: KRAR_RESOURCES
                  value: "deployments,statefulsets"
                - name: KRAR_LABEL_DOMAIN
                  value: "krar.slash-mnt.com"
                - name: KRAR_LABEL_NAME
                  value: "rollout-policy"
                - name: KRAR_LABEL_VALUE
                  value: "critical"
                - name: KRAR_MODE
                  value: "smart"
                - name: KRAR_SMART_RESTART
                  value: "true"
                # Tell krar where the auth file is mounted
                - name: KRAR_REGISTRY_AUTHFILE
                  value: "/config/config.json"
              volumeMounts:
                - name: docker-config
                  mountPath: /config
                  readOnly: true
          volumes:
            - name: docker-config
              secret:
                secretName: docker-config
                items:
                  - key: config.json
                    path: config.json
```

In this setup:

* The secret `docker-config` contains a standard Docker config.json.
* It is mounted as `/config/config.json` in the krar container.
* `KRAR_REGISTRY_AUTHFILE=/config/config.json` instructs skopeo to use that file for registry authentication.
* krar runs in `smart` mode and will:
  * detect digest drift for the selected workloads,
  * and trigger a `kubectl rollout restart` automatically when drift is found (because `KRAR_SMART_RESTART=true`).

### Example: CronJob using a custom DOCKER_CONFIG directory

As an alternative, you can mount a Docker config directory and let `skopeo` use it through `DOCKER_CONFIG`:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: krar-smart-private-docker-config
spec:
  schedule: "0 * * * *" # every hour
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          serviceAccountName: krar
          containers:
            - name: krar
              image: docker.io/slasmnt/krar:1.0.0
              env:
                - name: KRAR_RESOURCES
                  value: "deployments"
                - name: KRAR_LABEL_DOMAIN
                  value: "krar.slash-mnt.com"
                - name: KRAR_LABEL_NAME
                  value: "rollout-policy"
                - name: KRAR_LABEL_VALUE
                  value: "staging"
                - name: KRAR_MODE
                  value: "smart"
                - name: KRAR_SMART_RESTART
                  value: "false" # report-only
                # Directory containing config.json
                - name: KRAR_DOCKER_CONFIG
                  value: "/docker-config"
              volumeMounts:
                - name: docker-config-dir
                  mountPath: /docker-config
                  readOnly: true
          volumes:
            - name: docker-config-dir
              secret:
                secretName: docker-config-dir
                # secret should contain a "config.json" key
```

In this variant:
* The secret `docker-config-dir` contains a `config.json` file.
* It is mounted as `/docker-config/config.json`.
* `KRAR_DOCKER_CONFIG=/docker-config` is exported to DOCKER_CONFIG, so `skopeo` uses `/docker-config/config.json` transparently.
* krar runs in `smart` mode but with `KRAR_SMART_RESTART=false`, so it only reports drift, without restarting workloads.

### Labels & Selection Logic

Your workloads need a label scoped by domain:

Example:

```yaml
metadata:
  labels:
    krar.slash-mnt.com/rollout-policy: once-a-month
```

krar constructs a label selector: `<label-domain>/<label-name>=<label-value>`

Examples:

* `krar.slash-mnt.com/rollout-policy=once-a-month`
* `example.com/restart=nightly`

## Registry Digest Comparison Logic

When running in check-images mode, krar:

1. Finds matching Pods
2. Extracts their imageID, e.g.: `docker-pullable://registry.io/app@sha256:abc123...`
3. Normalizes the digest: `sha256:abc123`
4. Uses `skopeo inspect` on the image tag: `skopeo inspect docker://registry.io/app:latest`
5. Compares

This detects:

* Mutable tag drifts
* Forced pushes
* Rebuilds of `stable`, `1.0.0`, etc.
* Registry mirroring differences

## Practical use case

* Monthly restart of Java services to free fragmented heap
* Nightly restart of sidecars
* Scheduler-driven rotation of workload pools
* Detect new rebuilds in environments where tags are reused
* Validate that running containers match your registry state

## Multi-architecture Support

Images are published as multi-arch manifests:

* linux/amd64
* linux/arm64

Tagging logic ensures:

* Semantic versioning (`1.0.0` > `0.9.1`)
* `latest` tracks the highest semantic version, not publish date

Example:

```
docker.io/slasmnt/krar:1.0.0
docker.io/slasmnt/krar:latest   # if 1.0.0 is highest version
```

## Development & Testing

Run help locally:

```
./run.sh --help
```

Test smart mode:

```
./run.sh \
  --mode smart \
  --resources "deployments" \
  --label-domain "krar.slash-mnt.com" \
  --label-name "rollout-policy" \
  --label-value "demo"
```

Test smart mode with auto-restart:

```
./run.sh \
  --mode smart \
  --smart-restart \
  --resources "deployments" \
  --label-domain "krar.slash-mnt.com" \
  --label-name "rollout-policy" \
  --label-value "demo"
```

## Notes & Recommendations

* Prefer namespaces-specific selection in multi-tenant clusters
* Avoid mutable tags (latest) unless needed — but krar helps mitigate risks
* Run in read-only filesystem mode if desired (except temporary YAML file)
* Use --dry-run for debugging your label strategy

## License

Distributed under the GPL-v3 License.
See [LICENSE](../LICENSE) for full text.