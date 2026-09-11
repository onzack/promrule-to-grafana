# PromRule-To-Grafana

Mirrors `PrometheusRule` **alerting** rules from every namespace of a cluster into a Grafana instance as Grafana-managed alert rules.

A single-replica Deployment runs a shell loop that, every 30 seconds:

1. lists `PrometheusRules` across all namespaces with `kubectl`,
2. reshapes them with `yq`, keeping alerting rules and dropping recording rules,
3. validates the result with `mimirtool rules check`,
4. pushes it with `mimirtool rules sync` when the rule set changed.

## How the pieces fit together

Grafana performs the actual conversion from Prometheus rule format to Grafana-managed rules, server-side, at `POST /api/convert/prometheus/config/v1/rules`. `mimirtool` is only the client. Grafana cannot read `PrometheusRule` custom resources, which is why the `kubectl` and `yq` steps exist.

`mimirtool` is used rather than plain `curl` for two reasons: `rules check` validates rules locally before they are pushed, and `rules sync` diffs against what is already in Grafana and **deletes** rules that no longer exist in the cluster. The bulk POST endpoint only creates and updates.

## Folders and group names

A mimirtool namespace becomes a Grafana folder. By default every rule is collected into a single folder:

```yaml
rules:
  folder: "Prometheus Synced Rules"
```

The folder is created on the first sync if it does not exist. All `PrometheusRules` that resolve to the same folder are merged into one rule file, because a mimirtool rule file holds exactly one namespace.

Since a group name has to be unique within its folder, group names are prefixed with their origin, so a `general.rules` group in two different resources becomes `monitoring-kube-apiserver-slos-general.rules` and `team-a-team-rules-general.rules` rather than one silently overwriting the other:

```yaml
rules:
  groupNameExpr: '$m.namespace + "-" + $m.name + "-" + .name'
```

For one folder per `PrometheusRule` instead, clear `folder` and drop the prefix, which reads better when the folder name already carries the origin:

```yaml
rules:
  folder: ""
  namespaceExpr: '$m.namespace + "-" + $m.name'
  groupNameExpr: '.name'
```

In both expressions `$m` is the resource's `.metadata` and, inside `groupNameExpr`, `.name` is the group name as authored in the resource. They are yq code embedded into the sync script, so treat them as trusted input the same way you would any other chart template. `rules.folder` is a plain title rather than an expression and is passed through the environment, so quotes and apostrophes in it are safe.

`grafana.folderUID` is a different, lower-level mechanism: it sends the `X-Grafana-Alerting-Folder-UID` header, which requires the UID of a folder that already exists. `rules.folder` addresses a folder by title and creates it on demand, so it is usually what you want.

## Requirements

- Grafana 12 or newer, with the `/api/convert/` endpoints enabled.
- A Grafana service account token with the **Alerting: Write** (`alert.rules:write`) permission.
- The `PrometheusRule` CRD installed, e.g. from kube-prometheus-stack.
- The UID of the Prometheus data source the imported rules should query.

## Install

```console
helm install rule-sync ./charts/promrule-to-grafana \
  --namespace monitoring \
  --set grafana.url=https://grafana.example.com \
  --set grafana.datasourceUID=PBFA97CFB590B2093 \
  --set grafana.auth.existingSecret=grafana-rule-sync-token
```

The chart refuses to render without a token, rather than deploying something that would return 401 forever.

## Uninstall

`helm uninstall` runs a pre-delete Job that:

1. scales the sync Deployment to zero, so the loop cannot push the rules back,
2. deletes every Grafana folder this release wrote to, via `mimirtool rules delete-namespace` against `/api/convert/`.

With the default `rules.folder`, that is the single folder `Prometheus Synced Rules`. When `rules.folder` is empty, the Job lists the current `PrometheusRules` and deletes each derived folder. Extra titles can be listed under `cleanup.extraNamespaces`.

Only rules imported through `/api/convert/` are deleted. Alert rules created in the Grafana UI are left alone. Empty Grafana folders may remain after the rule groups are gone.

```yaml
cleanup:
  enabled: true
  timeout: 10m
  extraNamespaces: []
```

If Grafana is already gone, the Job cannot finish and uninstall waits until the Helm timeout. Skip it with `--no-hooks`, or set `cleanup.enabled=false` and upgrade once before uninstalling.

## Grafana token

### Production: an existing Secret

```yaml
grafana:
  auth:
    existingSecret: grafana-rule-sync-token
    existingSecretKey: token
```

The Secret can come from anywhere, including an `ExternalSecret` shipped with the release through `extraManifests`:

```yaml
grafana:
  auth:
    existingSecret: grafana-rule-sync-token

extraManifests:
  - apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: '{{ include "promrule-to-grafana.fullname" . }}-grafana-token'
    spec:
      refreshInterval: 1h
      secretStoreRef:
        name: vault
        kind: ClusterSecretStore
      target:
        name: grafana-rule-sync-token
      data:
        - secretKey: token
          remoteRef:
            key: monitoring/grafana
            property: rule-sync-token
```

`extraManifests` entries may be maps or raw strings and are rendered through `tpl`, so they can use chart helpers and values as shown above. It works for any manifest, not just secrets: NetworkPolicies, PodDisruptionBudgets, and so on.

### Debugging: inline

```yaml
grafana:
  auth:
    token: glsa_xxxxxxxxxxxxxxxx
```

This renders a chart-managed Secret. Convenient, but the token then lives in your values file and in the Helm release stored in the cluster, so it is not meant for anything permanent. Setting both `token` and `existingSecret` is an error.

## Pinning CLI tool versions

Every tool defaults to its latest release. Pin one if an upstream release breaks the sync:

```yaml
tools:
  mimirtool:
    version: "3.2.1"
  kubectl:
    version: "1.34.1"
  yq:
    version: "4.47.1"
```

Precedence per tool is `url`, then `version`, then the binary already in the base image, then the latest release. A leading `v` in a version is optional. Use `url` to pull from an internal mirror in air-gapped clusters:

```yaml
tools:
  mimirtool:
    url: https://artifacts.internal/mimirtool-linux-amd64
```

The init container runs each binary once after installing it, so a wrong architecture or an HTML error page saved as a binary fails the pod at startup instead of halfway through a sync.

### Why `alpine/k8s` as the base image

`mimirtool` has to be downloaded at runtime because the official `grafana/mimirtool` image is distroless as of 2.17.2: it has no shell and no `cp`, so it can serve neither as a base image for a shell loop nor as an init container that copies its binary out. `registry.k8s.io/kubectl` is distroless too, and the Bitnami images are legacy.

`alpine/k8s` bundles `kubectl`, `yq`, `jq`, `curl`, `bash` and `sha256sum`, which reduces the runtime download from roughly 170 MB (kubectl 57 MB, yq 11 MB, mimirtool ~100 MB) to just mimirtool. The image tag tracks the bundled `kubectl` version. The transform needs `yq` 4.31 or newer for `pick`; pin `tools.yq` if the image ever ships something older.

Downloads happen once per pod start, not once per sync iteration.

## Selecting which rules to sync

```yaml
rules:
  # only rules carrying this label
  labelSelector: release=kube-prometheus-stack
  # anchored regexes; empty `namespaces` means all
  namespaces: []
  excludeNamespaces:
    - kube-system
    - kube-public
```

Entries in `namespaces` and `excludeNamespaces` are combined into anchored regular expressions, so `team-.*` works and `kube-system` matches only that namespace. Exclusion wins over inclusion.

A single resource can opt out without touching the chart:

```console
kubectl annotate prometheusrule noisy-rules promrule-to-grafana/ignore=true
```

Recording rules are always dropped. A rule is treated as alerting only if it has a non-empty `alert` field and no `record` field at all, so a malformed rule carrying both keys is dropped rather than imported as an alert. A group left with no alerting rules is dropped, and a `PrometheusRule` left with no groups is skipped entirely, so no empty rule group is ever created in Grafana. Group and rule keys that the endpoint does not accept, such as `partial_response_strategy` and `limit`, are stripped.

Before pushing, the loop re-reads its own output and refuses to sync if any group is empty or holds a rule without an alert name. Grafana's `/api/convert/` endpoint accepts recording rules, so without that check a regression in the transform would create them silently instead of failing.

## Sync behaviour

```yaml
sync:
  interval: 30s
  fullSyncInterval: 5m
  timeout: 5m
  dryRun: false
  allowEmpty: false
```

Rules are only pushed when the rendered rule set actually changed, compared by hash, which keeps the request volume low at a 30 second interval. `fullSyncInterval` forces a push at least that often so that changes made directly in the Grafana UI get reverted; set it to `0` to only ever push on change.

`dryRun` swaps `mimirtool rules sync` for `mimirtool rules diff`: the loop reports what would change and writes nothing.

A failing iteration is logged and retried on the next tick rather than crashing the container, because the usual causes, such as Grafana restarting or an expired token, are not fixed by a restart.

### Deletion, and the empty rule set

`mimirtool rules sync` mirrors: rules that no longer exist in the cluster are **deleted** from Grafana. Only rules previously imported through `/api/convert/` are visible to it, so alert rules created by hand in the Grafana UI are never touched.

That has one sharp edge. If no `PrometheusRule` matches, for example because the CRD was momentarily unavailable or a label selector was mistyped, a literal mirror would delete every imported rule. Such an iteration is therefore skipped with a warning. Set `sync.allowEmpty=true` if you genuinely want an empty cluster to mean an empty Grafana.

### Rules this chart cannot clean up

`mimirtool rules sync` only ever sees what `GET /api/convert/` returns, which is the set of rules that were imported through that same endpoint. Anything that reached Grafana another way is invisible to it: it is never updated and, more importantly, never deleted. That includes alert rules created in the Grafana UI, which is the point, but also rules pushed by an earlier importer of your own.

A hand-rolled predecessor of this chart is a common source of such leftovers. The typical shape is a CronJob doing `mimirtool rules load --address=<grafana>/api/ruler/grafana`, which writes straight to the Grafana-managed ruler API rather than through the conversion endpoint. Two symptoms give it away:

- rule groups named after **recording** rule groups, such as `kube-apiserver-availability.rules`, `k8s.rules.pod_owner`, `node-recording.rules` or anything `*-recording-rules-*`, and
- rule groups that are **empty**, because the importer filtered the rules out of the group but still pushed the group itself.

Neither can be produced by this chart, so if you see them they predate it. List what is actually under this chart's control and compare:

```console
# what this chart manages: everything reachable through the conversion endpoint
mimirtool rules list --address=https://grafana.example.com/api/convert/ --id=1 --key="$TOKEN"

# what the loop last rendered, i.e. what it will converge Grafana on
kubectl exec -n monitoring deploy/rule-sync-promrule-to-grafana \
  -- sh -c 'cat /tmp/rules/*.yml'
```

Any rule group present in Grafana but in neither listing is a leftover. Delete those in the Grafana UI under **Alerting -> Alert rules**, or with `mimirtool rules delete --namespace=<folder> --rule-group=<group>` pointed at the same `/api/ruler/grafana` address the old importer used. Deleting them is safe with respect to this chart: it will re-create anything that still has a matching `PrometheusRule` on the next iteration.

Point the old importer's address at a throwaway folder, or remove it entirely, before doing the cleanup, otherwise it will simply push the leftovers back.

## Operating

```console
# follow the loop
kubectl logs -n monitoring -l app.kubernetes.io/name=promrule-to-grafana -f

# inspect the rule files that were last pushed
kubectl exec -n monitoring deploy/rule-sync-promrule-to-grafana \
  -- sh -c 'cat /tmp/rules/*.yml'

# see the raw PrometheusRule list the last iteration read
kubectl exec -n monitoring deploy/rule-sync-promrule-to-grafana \
  -- cat /tmp/state/prometheusrules.json
```

Set `sync.debug=true` to trace every command with `set -x`.

The liveness probe compares a heartbeat file against `sync.timeout + 2 * sync.interval`. It deliberately reports healthy while sync is failing: it exists to restart a loop that has stopped iterating, not to react to Grafana errors, which are easier to read from a pod that stays up.

## Notable values

| Key | Default | Description |
| --- | --- | --- |
| `grafana.url` | `http://grafana-service.grafana.svc.cluster.local:3000` | Base URL; `/api/convert/` is appended |
| `grafana.datasourceUID` | `prometheus` | Data source the imported rules query. Required |
| `grafana.tenantId` | `"1"` | Must stay `1` when targeting Grafana rather than Mimir |
| `grafana.folderUID` | `""` | Import everything into one existing folder |
| `grafana.alertRulesPaused` | `false` | Import rules paused, so nothing fires yet |
| `grafana.auth.existingSecret` | `""` | Secret holding the service account token |
| `grafana.auth.token` | `""` | Inline token, debugging only |
| `grafana.tls.caSecret` | `""` | Secret with a CA bundle for verifying Grafana |
| `grafana.tls.insecureSkipVerify` | `false` | Skip certificate verification |
| `sync.interval` | `30s` | Time between iterations |
| `sync.fullSyncInterval` | `5m` | Push even when unchanged, to repair drift |
| `sync.concurrency` | `1` | Must stay 1; Grafana errors at mimirtool's default of 8 |
| `rules.folder` | `Prometheus Synced Rules` | Single folder for every rule; `""` means one folder per resource |
| `rules.namespaceExpr` | `$m.namespace + "-" + $m.name` | Folder name expression, used only when `rules.folder` is empty |
| `rules.groupNameExpr` | `$m.namespace + "-" + $m.name + "-" + .name` | Rule group name; must be unique within a folder |
| `cleanup.enabled` | `true` | Delete imported Grafana-managed alerts on uninstall |
| `cleanup.timeout` | `10m` | Deadline for the pre-delete cleanup Job |
| `cleanup.extraNamespaces` | `[]` | Extra Grafana folder titles to delete on uninstall |
| `extraManifests` | `[]` | Extra objects deployed with the release, rendered via `tpl` |

See [values.yaml](values.yaml) for the full set.

## RBAC

The chart creates a ClusterRole with `get` and `list` on `prometheusrules.monitoring.coreos.com` and binds it to the ServiceAccount. That access is read-only; PrometheusRules are never written back.

When `cleanup.enabled` is true, a namespaced Role also allows the ServiceAccount to scale the sync Deployment to zero, which the pre-delete Job needs so the loop is stopped before Grafana rules are removed.
