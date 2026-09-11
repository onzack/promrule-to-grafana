# PromRule-To-Grafana

![PromRule-To-Grafana](assets/promrule-to-grafana.png)

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

## Configuration

See `helm/values.yaml` for configuration options, and `helm/README.md` for the full value reference.

## Uninstall

`helm uninstall` runs a pre-delete Job that:

1. scales the sync Deployment to zero, so the loop cannot push the rules back,
2. deletes every Grafana folder this release wrote to, via `mimirtool rules delete-namespace` against `/api/convert/`.

With the default `rules.folder`, that is the single folder `Prometheus Synced Rules`. When `rules.folder` is empty, the Job lists the current `PrometheusRules` and deletes each derived folder. Extra titles can be listed under `cleanup.extraNamespaces`.

Only rules imported through `/api/convert/` are deleted. Alert rules created in the Grafana UI are left alone. Empty Grafana folders may remain after the rule groups are gone.
