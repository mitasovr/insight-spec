{{/*
==============================================================================
 Umbrella helpers
==============================================================================
Central place for release/component names (DRY) and service-reference
resolution. No separate `internal` vs `external` paths — each dep has a
single `host`/`port` field that either carries a default (empty → compute
from release name) or a user-supplied value (e.g. a Constructor Platform
hostname). The `deploy` flag only controls whether the umbrella itself
runs the dep as a subchart.

Every fail-fast check lives in `insight.validate` at the bottom.
==============================================================================
*/}}

{{- define "insight.fullname" -}}
{{- default .Release.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "insight.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: insight
{{- end -}}

{{/*
==============================================================================
 SERVICE RESOLUTION
==============================================================================
Contract per dep:
  - `<dep>.host` — if empty, defaults to the internal service name.
  - `<dep>.port` — required (has a value in values.yaml default).
  - `<dep>.url`  — composed "<scheme>://<host>:<port>" via helpers below.
  - `<dep>.fqdn` — fully-qualified DNS when the dep is internal, host
                   verbatim when external — useful for services that live
                   OUTSIDE the cluster but are resolved via kubelet.
==============================================================================
*/}}

{{/* ---------- ClickHouse ---------- */}}
{{- define "insight.clickhouse.host" -}}
{{- default (printf "%s-clickhouse" .Release.Name) .Values.clickhouse.host -}}
{{- end -}}

{{- define "insight.clickhouse.port" -}}
{{- required "clickhouse.port is required" .Values.clickhouse.port -}}
{{- end -}}

{{- define "insight.clickhouse.fqdn" -}}
{{- if .Values.clickhouse.deploy -}}
{{ include "insight.clickhouse.host" . }}.{{ .Release.Namespace }}.svc.cluster.local
{{- else -}}
{{ include "insight.clickhouse.host" . }}
{{- end -}}
{{- end -}}

{{- define "insight.clickhouse.url" -}}
http://{{ include "insight.clickhouse.host" . }}:{{ include "insight.clickhouse.port" . }}
{{- end -}}

{{- define "insight.clickhouse.database" -}}
{{- required "clickhouse.database is required" .Values.clickhouse.database -}}
{{- end -}}

{{/* ---------- MariaDB ---------- */}}
{{- define "insight.mariadb.host" -}}
{{- default (printf "%s-mariadb" .Release.Name) .Values.mariadb.host -}}
{{- end -}}

{{- define "insight.mariadb.port" -}}
{{- required "mariadb.port is required" .Values.mariadb.port -}}
{{- end -}}

{{- define "insight.mariadb.database" -}}
{{- required "mariadb.database is required" .Values.mariadb.database -}}
{{- end -}}

{{/* ---------- Redis ---------- */}}
{{- define "insight.redis.host" -}}
{{- default (printf "%s-redis-master" .Release.Name) .Values.redis.host -}}
{{- end -}}

{{- define "insight.redis.port" -}}
{{- required "redis.port is required" .Values.redis.port -}}
{{- end -}}

{{- define "insight.redis.url" -}}
redis://{{ include "insight.redis.host" . }}:{{ include "insight.redis.port" . }}
{{- end -}}

{{/* ---------- Redpanda ----------
     The Redpanda Helm chart exposes Kafka on two listeners:
       - 9093 — INTERNAL (in-cluster clients connect here)
       - 9092 — EXTERNAL (outside-cluster; goes through NodePort/LB)
     We resolve to the internal listener by default. Override via
     redpanda.brokers when pointing at an external cluster.
*/}}
{{- define "insight.redpanda.brokers" -}}
{{- default (printf "%s-redpanda:9093" .Release.Name) .Values.redpanda.brokers -}}
{{- end -}}

{{/*
==============================================================================
 AIRBYTE (separate release, SAME namespace)
==============================================================================
*/}}
{{- define "insight.airbyte.url" -}}
{{- if .Values.airbyte.apiUrl -}}
{{- .Values.airbyte.apiUrl -}}
{{- else -}}
http://{{ .Values.airbyte.releaseName }}-airbyte-server-svc.{{ .Release.Namespace }}.svc.cluster.local:8001
{{- end -}}
{{- end -}}

{{/*
==============================================================================
 APP SERVICE HOSTS
==============================================================================
App services are mandatory umbrella components — no deploy flag.
*/}}
{{- define "insight.apiGateway.host"          -}}{{- printf "%s-api-gateway"          .Release.Name -}}{{- end -}}
{{- define "insight.analyticsApi.host"        -}}{{- printf "%s-analytics-api"        .Release.Name -}}{{- end -}}
{{- define "insight.identityResolution.host"  -}}{{- printf "%s-identity-resolution" .Release.Name -}}{{- end -}}
{{- define "insight.frontend.host"            -}}{{- printf "%s-frontend"             .Release.Name -}}{{- end -}}

{{/*
==============================================================================
 VALIDATORS
==============================================================================
Fail-fast checks that run at helm template / install time.
Invoked from NOTES.txt so they fire on every install.
==============================================================================
*/}}
{{- define "insight.validate" -}}
  {{- /* OIDC: when auth is enabled, require either existingSecret or all
         three inline fields. Defensive `default dict` guards against
         aggressive override files that remove the whole apiGateway /
         apiGateway.oidc block — without these, a nil-map dereference
         would replace the fail message with a cryptic template error. */ -}}
  {{- $gw  := default dict .Values.apiGateway -}}
  {{- $oid := default dict $gw.oidc -}}
  {{- if not $gw.authDisabled -}}
    {{- if not $oid.existingSecret -}}
      {{- if or (not $oid.issuer) (not $oid.clientId) (not $oid.redirectUri) -}}
        {{- fail "apiGateway.oidc: when existingSecret is empty and authDisabled=false, issuer AND clientId AND redirectUri are ALL required" -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}

  {{- /* External-mode hosts: when a dep is not deployed by the umbrella,
         the consumer-facing host must be supplied. Internal deployments
         compute the host from the release name automatically. */ -}}
  {{- if and (not .Values.clickhouse.deploy) (not .Values.clickhouse.host) -}}
    {{- fail "clickhouse.deploy=false requires clickhouse.host" -}}
  {{- end -}}
  {{- if and (not .Values.mariadb.deploy) (not .Values.mariadb.host) -}}
    {{- fail "mariadb.deploy=false requires mariadb.host" -}}
  {{- end -}}
  {{- if and (not .Values.redis.deploy) (not .Values.redis.host) -}}
    {{- fail "redis.deploy=false requires redis.host" -}}
  {{- end -}}
  {{- if and (not .Values.redpanda.deploy) (not .Values.redpanda.brokers) -}}
    {{- fail "redpanda.deploy=false requires redpanda.brokers" -}}
  {{- end -}}

  {{- /* Passwords live in Secrets — never inline. Validate that the
         passwordSecret reference is present; the actual Secret may be
         auto-generated by the umbrella (credentials.autoGenerate=true),
         mirrored from a platform operator, or pre-created by the user. */ -}}
  {{- range $dep := list "clickhouse" "mariadb" "redis" -}}
    {{- $cfg := index $.Values $dep -}}
    {{- if not $cfg.passwordSecret.name -}}
      {{- fail (printf "%s.passwordSecret.name is required" $dep) -}}
    {{- end -}}
    {{- if not $cfg.passwordSecret.key -}}
      {{- fail (printf "%s.passwordSecret.key is required" $dep) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
