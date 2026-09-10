{{/* Chart name, overridable. */}}
{{- define "promrule-to-grafanarule-converter.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified release name. */}}
{{- define "promrule-to-grafanarule-converter.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "promrule-to-grafanarule-converter.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "promrule-to-grafanarule-converter.selectorLabels" -}}
app.kubernetes.io/name: {{ include "promrule-to-grafanarule-converter.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "promrule-to-grafanarule-converter.labels" -}}
helm.sh/chart: {{ include "promrule-to-grafanarule-converter.chart" . }}
{{ include "promrule-to-grafanarule-converter.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "promrule-to-grafanarule-converter.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "promrule-to-grafanarule-converter.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "promrule-to-grafanarule-converter.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}
{{- end -}}

{{/*
Converts a duration such as "30s", "5m", "2h" or a bare number of seconds into
seconds, so that the sync loop can do plain integer arithmetic.
*/}}
{{- define "promrule-to-grafanarule-converter.toSeconds" -}}
{{- $d := . | toString | trim -}}
{{- if regexMatch "^[0-9]+$" $d -}}
{{- $d -}}
{{- else if regexMatch "^[0-9]+s$" $d -}}
{{- trimSuffix "s" $d -}}
{{- else if regexMatch "^[0-9]+m$" $d -}}
{{- mul (trimSuffix "m" $d | int) 60 -}}
{{- else if regexMatch "^[0-9]+h$" $d -}}
{{- mul (trimSuffix "h" $d | int) 3600 -}}
{{- else -}}
{{- fail (printf "promrule-to-grafanarule-converter: cannot parse duration %q. Use a plain number of seconds or a value like 30s, 5m, 2h." $d) -}}
{{- end -}}
{{- end -}}

{{/* Address mimirtool talks to: the Grafana rule conversion endpoint. */}}
{{- define "promrule-to-grafanarule-converter.mimirAddress" -}}
{{- printf "%s/api/convert/" (.Values.grafana.url | trimSuffix "/") -}}
{{- end -}}

{{/* Name of the Secret holding the Grafana token. */}}
{{- define "promrule-to-grafanarule-converter.authSecretName" -}}
{{- if .Values.grafana.auth.existingSecret -}}
{{- .Values.grafana.auth.existingSecret -}}
{{- else -}}
{{- printf "%s-grafana-auth" (include "promrule-to-grafanarule-converter.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "promrule-to-grafanarule-converter.authSecretKey" -}}
{{- if .Values.grafana.auth.existingSecret -}}
{{- .Values.grafana.auth.existingSecretKey | default "token" -}}
{{- else -}}
{{- "token" -}}
{{- end -}}
{{- end -}}

{{/*
Headers mimirtool sends to Grafana, newline separated as MIMIR_EXTRA_HEADERS
expects. X-Grafana-Alerting-Datasource-UID is required by the POST endpoints.
*/}}
{{- define "promrule-to-grafanarule-converter.extraHeaders" -}}
{{- $headers := list (printf "X-Grafana-Alerting-Datasource-UID=%s" .Values.grafana.datasourceUID) -}}
{{- with .Values.grafana.folderUID -}}
{{- $headers = append $headers (printf "X-Grafana-Alerting-Folder-UID=%s" .) -}}
{{- end -}}
{{- if .Values.grafana.alertRulesPaused -}}
{{- $headers = append $headers "X-Grafana-Alerting-Alert-Rules-Paused=true" -}}
{{- end -}}
{{- range .Values.grafana.extraHeaders -}}
{{- $headers = append $headers . -}}
{{- end -}}
{{- join "\n" $headers -}}
{{- end -}}

{{/*
Age after which the liveness probe considers the loop stuck. An iteration can
legitimately take up to sync.timeout, and the heartbeat is written after it, so
the threshold has to clear timeout plus a couple of intervals.
*/}}
{{- define "promrule-to-grafanarule-converter.heartbeatMaxAge" -}}
{{- $interval := include "promrule-to-grafanarule-converter.toSeconds" .Values.sync.interval | int -}}
{{- $timeout := include "promrule-to-grafanarule-converter.toSeconds" .Values.sync.timeout | int -}}
{{- add $timeout (mul $interval 2) -}}
{{- end -}}

{{/*
Configuration errors that would otherwise surface as a pod that silently does
nothing or 401s forever.
*/}}
{{- define "promrule-to-grafanarule-converter.validate" -}}
{{- $auth := .Values.grafana.auth -}}
{{- if and $auth.token $auth.existingSecret -}}
{{- fail "promrule-to-grafanarule-converter: set either grafana.auth.token or grafana.auth.existingSecret, not both." -}}
{{- end -}}
{{- if not (or $auth.token $auth.existingSecret) -}}
{{- fail "promrule-to-grafanarule-converter: a Grafana service account token is required. Set grafana.auth.existingSecret to the name of a Secret holding it, or grafana.auth.token for a quick debugging run." -}}
{{- end -}}
{{- if not .Values.grafana.url -}}
{{- fail "promrule-to-grafanarule-converter: grafana.url is required." -}}
{{- end -}}
{{- if not (regexMatch "^https?://" (.Values.grafana.url | toString)) -}}
{{- fail (printf "promrule-to-grafanarule-converter: grafana.url must start with http:// or https://, got %q." (.Values.grafana.url | toString)) -}}
{{- end -}}
{{- if not .Values.grafana.datasourceUID -}}
{{- fail "promrule-to-grafanarule-converter: grafana.datasourceUID is required. It is sent as the X-Grafana-Alerting-Datasource-UID header and tells Grafana which data source the imported rules query." -}}
{{- end -}}
{{/* Coerced, because --set grafana.tenantId=2 yields an int rather than a string. */}}
{{- if ne (.Values.grafana.tenantId | toString) "1" -}}
{{- fail (printf "promrule-to-grafanarule-converter: grafana.tenantId must be \"1\" when targeting Grafana rather than a Mimir ruler, got %q." (.Values.grafana.tenantId | toString)) -}}
{{- end -}}
{{- if .Values.grafana.tls.caSecret -}}
{{- if not .Values.grafana.tls.caSecretKey -}}
{{- fail "promrule-to-grafanarule-converter: grafana.tls.caSecretKey is required when grafana.tls.caSecret is set." -}}
{{- end -}}
{{- end -}}
{{- if not (or .Values.rules.folder .Values.rules.namespaceExpr) -}}
{{- fail "promrule-to-grafanarule-converter: set rules.folder to collect every rule in one Grafana folder, or rules.namespaceExpr to derive a folder name per PrometheusRule." -}}
{{- end -}}
{{- if not .Values.rules.groupNameExpr -}}
{{- fail "promrule-to-grafanarule-converter: rules.groupNameExpr must not be empty." -}}
{{- end -}}
{{- end -}}

{{/* Human readable description of where rules end up, for NOTES.txt. */}}
{{- define "promrule-to-grafanarule-converter.folderDescription" -}}
{{- if .Values.rules.folder -}}
{{- printf "one folder, %q" .Values.rules.folder -}}
{{- else -}}
{{- printf "one folder per PrometheusRule, named by %s" .Values.rules.namespaceExpr -}}
{{- end -}}
{{- end -}}
