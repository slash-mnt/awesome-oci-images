#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[$(date +"%Y-%m-%dT%H:%M:%S%z")] $*"
}

print_help() {
  cat <<EOF
Usage: $0 [options]

Description:
  krar rollout helper. It selects Kubernetes workloads by label and/or explicit
  references and either:
    - triggers 'kubectl rollout restart' on them (mode: rollout), or
    - inspects the container images used by matching pods, compares the current
      digest with the registry digest for the same tag, and optionally restarts
      workloads if drift is detected (mode: smart).

Environment variables (all can be overridden by CLI options):

  # Core selection and behaviour
  KRAR_RESOURCES
      Comma-separated list of resource kinds.
      Example: "deployments,daemonsets,statefulsets"
      Used for label-based discovery.

  KRAR_LABEL_DOMAIN
      Label domain.
      Example: "krar.slash-mnt.com"

  KRAR_LABEL_NAME
      Label key name.
      Example: "rollout-policy"

  KRAR_LABEL_VALUE
      Label value. If unset, the script falls back to KRAR_JOB_NAME, then JOB_NAME.

  KRAR_TARGETS
      Optional explicit list of controller resources to target, in addition to
      label-based discovery.
      Format: "namespace/Kind/name" entries separated by commas.
      Examples:
        "automation/Deployment/n8n"
        "prod/StatefulSet/db"
        "infra/DaemonSet/log-agent"

  KRAR_NAMESPACES_ALL
      "true" to target all namespaces when using label-based discovery,
      "false" to restrict to KRAR_NAMESPACES.
      Default: "true"

  KRAR_NAMESPACES
      Comma-separated list of namespaces when KRAR_NAMESPACES_ALL is "false".
      Example: "default,production"

  KRAR_DRY_RUN
      "true" to only print what would be done, without calling 'kubectl rollout restart'.
      - In 'rollout' mode: no restart is performed, only listing.
      - In 'smart' mode: drifts are detected, but no restarts are executed.
      Default: "false"

  KRAR_JOB_NAME
      Optional logical job name used as a fallback for KRAR_LABEL_VALUE.

  KRAR_MODE
      Operating mode: "rollout" or "smart".
      - rollout : perform 'kubectl rollout restart' on all targeted resources.
      - smart   : detect image tag drift on pods behind targeted resources; optionally
                  restart only resources where drift is detected.
      Default: "rollout"

  KRAR_SMART_RESTART
      "true" to automatically restart workloads in 'smart' mode when drift is detected.
      "false" to report-only in 'smart' mode.
      Default: "false"

  # Registry authentication for private images (smart mode)
  KRAR_REGISTRY_AUTHFILE
      Optional path to an auth file (Docker config.json) to use with skopeo.
      If set, passed as '--authfile <path>'.

  KRAR_REGISTRY_CREDS
      Optional inline registry credentials in the form "username:password".
      If set (and KRAR_REGISTRY_AUTHFILE is not set), passed as '--creds username:password'.

  KRAR_DOCKER_CONFIG
      Optional path to a directory containing a 'config.json'.
      If set (and KRAR_REGISTRY_AUTHFILE / KRAR_REGISTRY_CREDS are not used),
      exported as DOCKER_CONFIG for skopeo and other Docker-compatible tools.

Notes:
  - Targeted resources are the union of label-selected resources and KRAR_TARGETS.
  - Pod discovery in 'smart' mode is based ONLY on ownership relations from the
    targeted controller resources (Deployments/StatefulSets/DaemonSets, via ReplicaSets
    if needed). No label/annotation is required on the Pods themselves.
  - Only containers whose effective imagePullPolicy is treated as "Always" are considered
    for drift detection and restart. If imagePullPolicy is missing, empty or null, it is
    considered as "Always". Containers with explicit "IfNotPresent" or "Never" are ignored.
  - For each rollout restart actually triggered, a Kubernetes Event is created on the
    target resource to ease auditing and debugging:
      * reason: KrarRolloutTriggered
      * type: Normal
      * source.component: krar
EOF
}

###############################################################################
# Configuration initialization
###############################################################################

KRAR_RESOURCES="${KRAR_RESOURCES:-}"
KRAR_LABEL_DOMAIN="${KRAR_LABEL_DOMAIN:-}"
KRAR_LABEL_NAME="${KRAR_LABEL_NAME:-}"
KRAR_LABEL_VALUE="${KRAR_LABEL_VALUE:-}"
KRAR_TARGETS="${KRAR_TARGETS:-}"
KRAR_NAMESPACES_ALL="${KRAR_NAMESPACES_ALL:-true}"
KRAR_NAMESPACES="${KRAR_NAMESPACES:-}"
KRAR_DRY_RUN="${KRAR_DRY_RUN:-false}"
KRAR_JOB_NAME="${KRAR_JOB_NAME:-${JOB_NAME:-}}"
KRAR_MODE="${KRAR_MODE:-rollout}"                    # rollout | smart
KRAR_SMART_RESTART="${KRAR_SMART_RESTART:-false}"    # only used in smart mode

# Registry auth related
KRAR_REGISTRY_AUTHFILE="${KRAR_REGISTRY_AUTHFILE:-}"
KRAR_REGISTRY_CREDS="${KRAR_REGISTRY_CREDS:-}"
KRAR_DOCKER_CONFIG="${KRAR_DOCKER_CONFIG:-}"

###############################################################################
# CLI arguments parsing
###############################################################################

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--resources)
      [[ $# -lt 2 ]] && { echo "ERROR: --resources requires a value."; exit 1; }
      KRAR_RESOURCES="$2"
      shift 2
      ;;
    -d|--label-domain)
      [[ $# -lt 2 ]] && { echo "ERROR: --label-domain requires a value."; exit 1; }
      KRAR_LABEL_DOMAIN="$2"
      shift 2
      ;;
    -n|--label-name)
      [[ $# -lt 2 ]] && { echo "ERROR: --label-name requires a value."; exit 1; }
      KRAR_LABEL_NAME="$2"
      shift 2
      ;;
    -v|--label-value)
      [[ $# -lt 2 ]] && { echo "ERROR: --label-value requires a value."; exit 1; }
      KRAR_LABEL_VALUE="$2"
      shift 2
      ;;
    -A|--namespaces-all)
      KRAR_NAMESPACES_ALL="true"
      shift 1
      ;;
    --no-namespaces-all)
      KRAR_NAMESPACES_ALL="false"
      shift 1
      ;;
    -N|--namespaces)
      [[ $# -lt 2 ]] && { echo "ERROR: --namespaces requires a value."; exit 1; }
      KRAR_NAMESPACES="$2"
      KRAR_NAMESPACES_ALL="false"
      shift 2
      ;;
    --dry-run)
      KRAR_DRY_RUN="true"
      shift 1
      ;;
    -j|--job-name)
      [[ $# -lt 2 ]] && { echo "ERROR: --job-name requires a value."; exit 1; }
      KRAR_JOB_NAME="$2"
      shift 2
      ;;
    --mode)
      [[ $# -lt 2 ]] && { echo "ERROR: --mode requires a value."; exit 1; }
      KRAR_MODE="$2"
      shift 2
      ;;
    --smart)
      KRAR_MODE="smart"
      shift 1
      ;;
    --smart-restart)
      KRAR_SMART_RESTART="true"
      shift 1
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option '$1'. Use --help for usage details."
      exit 1
      ;;
  esac
done

###############################################################################
# Validation and derived values
###############################################################################

case "$KRAR_MODE" in
  rollout|smart) ;;
  *)
    log "ERROR: Invalid KRAR_MODE '${KRAR_MODE}'. Allowed values: rollout, smart."
    exit 1
    ;;
esac

if [[ -z "$KRAR_RESOURCES" && -z "$KRAR_TARGETS" ]]; then
  log "ERROR: You must configure either KRAR_RESOURCES (for label-based discovery) or KRAR_TARGETS (explicit targets), or both."
  exit 1
fi

# Label value fallback
if [[ -z "$KRAR_LABEL_VALUE" ]]; then
  if [[ -n "$KRAR_JOB_NAME" ]]; then
    KRAR_LABEL_VALUE="$KRAR_JOB_NAME"
  elif [[ -n "${JOB_NAME:-}" ]]; then
    KRAR_LABEL_VALUE="$JOB_NAME"
  fi
fi

FILTER=""
if [[ -n "$KRAR_LABEL_DOMAIN" && -n "$KRAR_LABEL_NAME" && -n "$KRAR_LABEL_VALUE" ]]; then
  FILTER="${KRAR_LABEL_DOMAIN}/${KRAR_LABEL_NAME}=${KRAR_LABEL_VALUE}"
else
  if [[ -n "$KRAR_RESOURCES" ]]; then
    log "INFO: Label-based discovery may be disabled (missing KRAR_LABEL_DOMAIN/NAME/VALUE). Only KRAR_TARGETS will be used if set."
  fi
fi

if [[ -n "$KRAR_DOCKER_CONFIG" ]]; then
  export DOCKER_CONFIG="$KRAR_DOCKER_CONFIG"
  log "Using DOCKER_CONFIG='${DOCKER_CONFIG}' for registry authentication."
fi

log "Starting krar script."
log "Mode               : ${KRAR_MODE}"
log "Configuration:"
log "  Resources kinds   : ${KRAR_RESOURCES}"
log "  Label selector    : ${FILTER:-<none>}"
log "  Explicit targets  : ${KRAR_TARGETS:-<none>}"
log "  Namespaces all    : ${KRAR_NAMESPACES_ALL}"
log "  Namespaces list   : ${KRAR_NAMESPACES}"
log "  Dry run           : ${KRAR_DRY_RUN}"
log "  Smart restart     : ${KRAR_SMART_RESTART}"
log "  Job name (logical): ${KRAR_JOB_NAME}"
log "  Registry authfile : ${KRAR_REGISTRY_AUTHFILE}"
log "  Registry creds    : ${KRAR_REGISTRY_CREDS:+<set>}"
log "  Docker config dir : ${KRAR_DOCKER_CONFIG}"

###############################################################################
# Target resources discovery
###############################################################################

declare -A TARGET_RESOURCES=()   # key: "ns Kind name" -> "true"
rm -rf /tmp/TARGET_RESOURCES.txt && touch /tmp/TARGET_RESOURCES.txt

add_target_resource() {
  local ns="$1"
  local kind="$2"
  local name="$3"
  [[ -z "$ns" || -z "$kind" || -z "$name" ]] && return
  local key="${ns} ${kind} ${name}"
  echo "$key" >> /tmp/TARGET_RESOURCES.txt
  TARGET_RESOURCES["$key"]="true"
}

# 1) Label-based discovery via KRAR_RESOURCES + FILTER
if [[ -n "$KRAR_RESOURCES" && -n "$FILTER" ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    log "ERROR: jq is required for label-based discovery but is not available."
    exit 1
  fi

  if [[ "$KRAR_NAMESPACES_ALL" == "true" ]]; then
    log "Discovering resources by label in all namespaces."
    kubectl get "${KRAR_RESOURCES}" --all-namespaces --selector "${FILTER}" -o json 2>/dev/null \
    | jq -r '.items[] | "\(.metadata.namespace) \(.kind) \(.metadata.name)"' \
    | while read -r ns kind name; do
        add_target_resource "$ns" "$kind" "$name"
      done || true
  else
    if [[ -z "$KRAR_NAMESPACES" ]]; then
      log "ERROR: KRAR_NAMESPACES_ALL=false but KRAR_NAMESPACES is empty."
      exit 1
    fi
    IFS=',' read -ra NS_ARR <<< "$KRAR_NAMESPACES"
    for ns in "${NS_ARR[@]}"; do
      ns="$(echo "$ns" | xargs)"
      [[ -z "$ns" ]] && continue
      log "Discovering resources by label in namespace '${ns}'."
      kubectl get "${KRAR_RESOURCES}" -n "${ns}" --selector "${FILTER}" -o json 2>/dev/null \
      | jq -r '.items[] | "\(.metadata.namespace) \(.kind) \(.metadata.name)"' \
      | while read -r rns kind name; do
          add_target_resource "$rns" "$kind" "$name"
        done || true
    done
  fi
fi

# 2) Explicit targets via KRAR_TARGETS (union avec label-based)
if [[ -n "$KRAR_TARGETS" ]]; then
  log "Adding explicit targets from KRAR_TARGETS."
  IFS=',' read -ra TGT_ARR <<< "$KRAR_TARGETS"
  for ref in "${TGT_ARR[@]}"; do
    ref="$(echo "$ref" | xargs)"
    [[ -z "$ref" ]] && continue
    IFS='/' read -r ns kind name <<< "$ref" || {
      log "WARN: Invalid KRAR_TARGETS entry '${ref}'. Expected 'namespace/Kind/name'."
      continue
    }
    if [[ -z "$ns" || -z "$kind" || -z "$name" ]]; then
      log "WARN: Invalid KRAR_TARGETS entry '${ref}'."
      continue
    fi
    add_target_resource "$ns" "$kind" "$name"
  done
fi

if [[ -s /tmp/TARGET_RESOURCES.txt ]]; then
  while read line ; do
    TARGET_RESOURCES[$line]="true"
  done < /tmp/TARGET_RESOURCES.txt
fi

if [[ "${#TARGET_RESOURCES[@]}" -eq 0 ]]; then
  log "No target resources discovered (no labels matched and/or KRAR_TARGETS empty or invalid). Nothing to do."
  exit 0
fi

log "Target resources:"
for key in "${!TARGET_RESOURCES[@]}"; do
  log "  - ${key}"
done

# Namespaces where we will look for pods in smart mode
declare -A TARGET_NAMESPACES=()
for key in "${!TARGET_RESOURCES[@]}"; do
  ns="$(echo "$key" | awk '{print $1}')"
  TARGET_NAMESPACES["$ns"]="true"
done

###############################################################################
# Helpers
###############################################################################

declare -A DRIFTED_IMAGES=()      # image -> "true"
declare -A DRIFTED_RESOURCES=()   # "ns Kind name" -> "true"
declare -A RS_TO_OWNER_CACHE=()   # "ns/rsName" -> "ns kind name"

resolve_owner() {
  local ns="$1"
  local kind="$2"
  local name="$3"

  local out_ns="$ns"
  local out_kind="$kind"
  local out_name="$name"

  if [[ "$kind" == "ReplicaSet" ]]; then
    local cache_key="${ns}/${name}"
    if [[ -n "${RS_TO_OWNER_CACHE[$cache_key]:-}" ]]; then
      read -r out_ns out_kind out_name <<<"${RS_TO_OWNER_CACHE[$cache_key]}"
    else
      local owner
      owner="$(kubectl get rs "${name}" -n "${ns}" -o json 2>/dev/null \
        | jq -r '.metadata.ownerReferences[]? | select(.controller==true) | "\(.kind) \(.name)"' \
        | head -n1 || true)"
      if [[ -n "$owner" && "$owner" != "null null" ]]; then
        read -r out_kind out_name <<<"$owner"
        RS_TO_OWNER_CACHE[$cache_key]="${out_ns} ${out_kind} ${out_name}"
      fi
    fi
  fi

  # Always return ns kind name
  echo "${out_ns} ${out_kind} ${out_name}"
}

create_rollout_event() {
  local ns="$1"
  local kind="$2"
  local name="$3"

  local api_version="apps/v1"

  log "Creating Kubernetes Event for rollout on ${kind}/${name} in namespace '${ns}'."
  kubectl apply -f - >/dev/null 2>&1 <<EOF || log "WARN: Failed to create Event for ${kind}/${name} in namespace '${ns}'."
apiVersion: v1
kind: Event
metadata:
  generateName: krar-rollout-
  namespace: ${ns}
involvedObject:
  apiVersion: ${api_version}
  kind: ${kind}
  name: ${name}
  namespace: ${ns}
type: Normal
reason: KrarRolloutTriggered
message: "krar triggered rollout restart for ${kind}/${name} (mode=${KRAR_MODE}, smart_restart=${KRAR_SMART_RESTART}, dry_run=${KRAR_DRY_RUN})"
source:
  component: krar
firstTimestamp: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
}

check_image_update() {
  local image="$1"
  local image_id="$2"

  if ! command -v jq >/dev/null 2>&1; then
    log "ERROR: jq is required in smart mode but is not available."
    exit 1
  fi

  if ! command -v skopeo >/dev/null 2>&1; then
    log "ERROR: skopeo is required in smart mode but is not available."
    exit 1
  fi

  if [[ -z "$image_id" ]]; then
    log "WARN: No imageID found for image '${image}'. Skipping."
    return
  fi

  local current_digest="${image_id##*@}"
  current_digest="${current_digest#sha256:}"
  current_digest="sha256:${current_digest}"

  log "Checking image '${image}'. Current digest: ${current_digest}"

  local extra_args=()
  if [[ -n "$KRAR_REGISTRY_AUTHFILE" ]]; then
    extra_args+=(--authfile "$KRAR_REGISTRY_AUTHFILE")
    log "Using registry authfile '${KRAR_REGISTRY_AUTHFILE}' for image '${image}'."
  elif [[ -n "$KRAR_REGISTRY_CREDS" ]]; then
    extra_args+=(--creds "$KRAR_REGISTRY_CREDS")
    log "Using inline registry credentials for image '${image}'."
  else
    log "Using default registry auth configuration for image '${image}'."
  fi

  local remote_digest
  if ! remote_digest="$(
    skopeo inspect "${extra_args[@]}" --retry-times 3 "docker://${image}" 2>/dev/null \
    | jq -r '.Digest // ""'
  )"; then
    log "WARN: Failed to inspect remote image '${image}' with skopeo."
    return
  fi

  if [[ -z "$remote_digest" ]]; then
    log "WARN: Remote digest for image '${image}' is empty. Skipping."
    return
  fi

  log "Remote digest for '${image}': ${remote_digest}"

  if [[ "$remote_digest" == "$current_digest" ]]; then
    log "RESULT: Image '${image}' is up-to-date (same digest)."
  else
    log "RESULT: Newer image detected for '${image}' under the same tag!"
    log "        Current digest: ${current_digest}"
    log "        Remote  digest: ${remote_digest}"
    DRIFTED_IMAGES["$image"]="true"
  fi
}

###############################################################################
# Mode: smart
###############################################################################
if [[ "$KRAR_MODE" == "smart" ]]; then
  log "Running in 'smart' mode."

  if ! command -v jq >/dev/null 2>&1; then
    log "ERROR: jq is required in smart mode but is not available."
    exit 1
  fi

  declare -A CURRENT_IMAGE_IDS=()
  rm -rf /tmp/CURRENT_IMAGE_IDS.txt && touch /tmp/CURRENT_IMAGE_IDS.txt
  rm -rf /tmp/DRIFTED_RESOURCES.txt && touch /tmp/DRIFTED_RESOURCES.txt

  # 1) image -> imageID from pods owned by targeted resources (containers only)
  for ns in "${!TARGET_NAMESPACES[@]}"; do
    log "Inspecting pods in namespace '${ns}' for targeted resources."
    kubectl get pods -n "${ns}" -o json 2>/dev/null \
    | jq -r '
        .items[] as $pod
        | ($pod.metadata.ownerReferences[]? | select(.controller==true)) as $owner
        | ($pod.status.containerStatuses[]? as $cs
           | ($pod.spec.containers[]? | select(.name == $cs.name) | .imagePullPolicy // "Always") as $ipp
           | "\($pod.metadata.namespace) \($owner.kind) \($owner.name) \($cs.image) \($cs.imageID) \($ipp)"
          )
      ' \
    | while read -r pod_ns owner_kind owner_name image image_id ipp; do
        [[ -z "$pod_ns" || -z "$owner_kind" || -z "$owner_name" || -z "$image" ]] && continue

        # Resolve owner and filter on TARGET_RESOURCES first
        read -r res_ns canonical_kind canonical_name <<<"$(resolve_owner "$pod_ns" "$owner_kind" "$owner_name")"
        key="${res_ns} ${canonical_kind} ${canonical_name}"
        if [[ -z "${TARGET_RESOURCES[$key]:-}" ]]; then
          # Pod is not owned by a targeted controller; ignore silently
          continue
        fi

        # Normalize: empty or null IPP = Always
        if [[ -z "$ipp" || "$ipp" == "null" ]]; then
          ipp="Always"
        fi

        if [[ "$ipp" != "Always" ]]; then
          log "Skipping image '${image}' in namespace '${pod_ns}' (controller ${canonical_kind}/${canonical_name}) because imagePullPolicy=${ipp} (not Always)."
          continue
        fi

        if [[ -z "${CURRENT_IMAGE_IDS[$image]:-}" ]]; then
          echo "$image $image_id" >> /tmp/CURRENT_IMAGE_IDS.txt
        fi
      done || true
  done

  if [[ -s /tmp/CURRENT_IMAGE_IDS.txt ]]; then
    while read line ; do
      image=$(echo $line | awk '{print $1}')
      image_id=$(echo $line | awk '{print $NF}')
      CURRENT_IMAGE_IDS[$image]="$image_id"
    done < /tmp/CURRENT_IMAGE_IDS.txt
  fi

  if [[ "${#CURRENT_IMAGE_IDS[@]}" -eq 0 ]]; then
    log "No eligible pods (with effective imagePullPolicy=Always) for targeted resources were found; nothing to compare."
    log "Completed smart mode (nothing to compare)."
    exit 0
  fi

  log "Discovered ${#CURRENT_IMAGE_IDS[@]} unique image(s) to check for drift."
  for image in "${!CURRENT_IMAGE_IDS[@]}"; do
    check_image_update "$image" "${CURRENT_IMAGE_IDS[$image]}"
  done

  if [[ "${#DRIFTED_IMAGES[@]}" -eq 0 ]]; then
    log "No image drift detected; all images are up-to-date for their tags."
    log "Completed 'smart' mode."
    exit 0
  fi

  log "Images with detected drift:"
  for img in "${!DRIFTED_IMAGES[@]}"; do
    log "  - ${img}"
  done

  # 2) Map drifted images back to controller resources (subset of TARGET_RESOURCES)
  log "Mapping drifted images back to controller resources."
  for ns in "${!TARGET_NAMESPACES[@]}"; do
    kubectl get pods -n "${ns}" -o json 2>/dev/null \
    | jq -r '
        .items[] as $pod
        | ($pod.metadata.ownerReferences[]? | select(.controller==true)) as $owner
        | ($pod.status.containerStatuses[]? as $cs
           | ($pod.spec.containers[]? | select(.name == $cs.name) | .imagePullPolicy // "Always") as $ipp
           | "\($pod.metadata.namespace) \($owner.kind) \($owner.name) \($cs.image) \($ipp)"
          )
      ' \
    | while read -r pod_ns owner_kind owner_name image ipp; do
        [[ -z "$pod_ns" || -z "$owner_kind" || -z "$owner_name" || -z "$image" ]] && continue

        # Resolve owner and filter on TARGET_RESOURCES first
        read -r res_ns canonical_kind canonical_name <<<"$(resolve_owner "$pod_ns" "$owner_kind" "$owner_name")"
        key="${res_ns} ${canonical_kind} ${canonical_name}"

        if [[ -z "${TARGET_RESOURCES[$key]:-}" ]]; then
          continue
        fi

        # Normalize: empty or null IPP = Always
        if [[ -z "$ipp" || "$ipp" == "null" ]]; then
          ipp="Always"
        fi

        if [[ "$ipp" != "Always" ]]; then
          continue
        fi

        if [[ -z "${DRIFTED_IMAGES[$image]:-}" ]]; then
          continue
        fi

        echo "$key" >> /tmp/DRIFTED_RESOURCES.txt
      done || true
  done

  if [[ -s /tmp/DRIFTED_RESOURCES.txt ]]; then
    while read line ; do
      DRIFTED_RESOURCES[$line]="true"
    done < /tmp/DRIFTED_RESOURCES.txt
  fi

  if [[ "${#DRIFTED_RESOURCES[@]}" -eq 0 ]]; then
    log "Drift detected on some images, but no matching targeted controller resource (with effective imagePullPolicy=Always) was found."
    log "Completed 'smart' mode."
    exit 0
  fi

  log "Controller resources with drift detected (effective imagePullPolicy=Always):"
  for key in "${!DRIFTED_RESOURCES[@]}"; do
    log "  - ${key}"
  done

  if [[ "$KRAR_SMART_RESTART" == "true" ]]; then
    if [[ "$KRAR_DRY_RUN" == "true" ]]; then
      log "Dry run enabled; listing controller resources that would be restarted due to drift:"
      for key in "${!DRIFTED_RESOURCES[@]}"; do
        log "DRY-RUN restart: ${key}"
      done
    else
      log "Triggering 'kubectl rollout restart' only for controller resources with drift."
      for key in "${!DRIFTED_RESOURCES[@]}"; do
        ns="$(echo "$key" | awk '{print $1}')"
        kind="$(echo "$key" | awk '{print $2}')"
        name="$(echo "$key" | awk '{print $3}')"
        kind_lc="$(echo "$kind" | tr '[:upper:]' '[:lower:]')"
        log "Restarting ${kind_lc}/${name} in namespace '${ns}'."
        kubectl rollout restart -n "${ns}" "${kind_lc}/${name}"
        create_rollout_event "${ns}" "${kind}" "${name}"
      done
    fi
  else
    log "KRAR_SMART_RESTART=false; reporting drift only. No rollout will be performed."
  fi

  log "Completed 'smart' mode."
  exit 0
fi

###############################################################################
# Mode: rollout (default)
###############################################################################

log "Running in 'rollout' mode."

if [[ "$KRAR_DRY_RUN" == "true" ]]; then
  log "Dry run enabled; listing controller resources that would be restarted:"
  for key in "${!TARGET_RESOURCES[@]}"; do
    log "DRY-RUN restart: ${key}"
  done
  exit 0
fi

log "Triggering 'kubectl rollout restart' on all targeted resources."
for key in "${!TARGET_RESOURCES[@]}"; do
  ns="$(echo "$key" | awk '{print $1}')"
  kind="$(echo "$key" | awk '{print $2}')"
  name="$(echo "$key" | awk '{print $3}')"
  kind_lc="$(echo "$kind" | tr '[:upper:]' '[:lower:]')"
  log "Restarting ${kind_lc}/${name} in namespace '${ns}'."
  kubectl rollout restart -n "${ns}" "${kind_lc}/${name}"
  create_rollout_event "${ns}" "${kind}" "${name}"
done

log "Completed rollout mode successfully."
exit 0
