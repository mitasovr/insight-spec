{{/*
==============================================================================
 Umbrella helpers
==============================================================================
Central place for:
  - release/component names (DRY)
  - service reference resolution (internal vs external) via enabled-gate
  - fail-fast validators for required fields

Any template that needs a dependency host/port/URL uses a helper rather
than hardcoding the name. If SRE ever decides to rename a component,
only this file changes.
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
 SERVICE RESOLUTION HELPERS
==============================================================================
Contract: each helper returns either the internal DNS (if the subchart is
enabled) or the value from external.* (if enabled=false). Fails if external
is missing while the subchart is disabled — this catches misconfiguration
at helm template / install time, before anything hits the cluster.
==============================================================================
*/}}

{{/* ---------- ClickHouse ---------- */}}
{{- define "insight.clickhouse.host" -}}
{{- if .Values.clickhouse.enabled -}}
{{- printf "%s-clickhouse" .Release.Name -}}
{{- else -}}
{{- required "clickhouse.enabled=false requires clickhouse.external.host" .Values.clickhouse.external.host -}}
{{- end -}}
{{- end -}}

{{- define "insight.clickhouse.port" -}}
{{- if .Values.clickhouse.enabled -}}
8123
{{- else -}}
{{- required "clickhouse.enabled=false requires clickhouse.external.port" .Values.clickhouse.external.port -}}
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
{{- if .Values.mariadb.enabled -}}
{{- printf "%s-mariadb" .Release.Name -}}
{{- else -}}
{{- required "mariadb.enabled=false requires mariadb.external.host" .Values.mariadb.external.host -}}
{{- end -}}
{{- end -}}

{{- define "insight.mariadb.port" -}}
{{- if .Values.mariadb.enabled -}}
3306
{{- else -}}
{{- required "mariadb.enabled=false requires mariadb.external.port" .Values.mariadb.external.port -}}
{{- end -}}
{{- end -}}

{{- define "insight.mariadb.database" -}}
{{- if .Values.mariadb.enabled -}}
{{- required "mariadb.auth.database is required" .Values.mariadb.auth.database -}}
{{- else -}}
{{- required "mariadb.external.database is required" .Values.mariadb.external.database -}}
{{- end -}}
{{- end -}}

{{/* ---------- Redis ---------- */}}
{{- define "insight.redis.host" -}}
{{- if .Values.redis.enabled -}}
{{- printf "%s-redis-master" .Release.Name -}}
{{- else -}}
{{- required "redis.enabled=false requires redis.external.host" .Values.redis.external.host -}}
{{- end -}}
{{- end -}}

{{- define "insight.redis.port" -}}
{{- if .Values.redis.enabled -}}
6379
{{- else -}}
{{- required "redis.enabled=false requires redis.external.port" .Values.redis.external.port -}}
{{- end -}}
{{- end -}}

{{- define "insight.redis.url" -}}
redis://{{ include "insight.redis.host" . }}:{{ include "insight.redis.port" . }}
{{- end -}}

{{/* ---------- Redpanda ---------- */}}
{{- define "insight.redpanda.brokers" -}}
{{- if .Values.redpanda.enabled -}}
{{- printf "%s-redpanda:9092" .Release.Name -}}
{{- else -}}
{{- required "redpanda.enabled=false requires redpanda.external.brokers" .Values.redpanda.external.brokers -}}
{{- end -}}
{{- end -}}

{{/* ---------- App service DNS (always internal, always umbrella-managed) ---------- */}}
{{- define "insight.apiGateway.host"   -}}{{- printf "%s-api-gateway"          .Release.Name -}}{{- end -}}
{{- define "insight.analyticsApi.host" -}}{{- printf "%s-analytics-api"        .Release.Name -}}{{- end -}}
{{- define "insight.identity.host"     -}}{{- printf "%s-identity-resolution" .Release.Name -}}{{- end -}}
{{- define "insight.frontend.host"     -}}{{- printf "%s-frontend"             .Release.Name -}}{{- end -}}

{{/*
==============================================================================
 VALIDATORS
==============================================================================
Fail-fast checks that run at helm template / install time.
Invoked from NOTES.txt so they fire on every install.
==============================================================================
*/}}
{{- define "insight.validate" -}}
  {{- /* OIDC is required when the gateway is on and auth is not disabled */ -}}
  {{- if and .Values.apiGateway.enabled (not .Values.apiGateway.authDisabled) -}}
    {{- if and (not .Values.apiGateway.oidc.existingSecret) (not .Values.apiGateway.oidc.issuer) -}}
      {{- fail "apiGateway.oidc: either existingSecret OR inline issuer+clientId+redirectUri must be set when authDisabled=false" -}}
    {{- end -}}
  {{- end -}}

  {{- /* External service references also validated via helpers, but making the intent explicit here */ -}}
  {{- if and (not .Values.clickhouse.enabled) (not .Values.clickhouse.external.host) -}}
    {{- fail "clickhouse.enabled=false requires clickhouse.external.host" -}}
  {{- end -}}
  {{- if and (not .Values.mariadb.enabled)    (not .Values.mariadb.external.host)    -}}
    {{- fail "mariadb.enabled=false requires mariadb.external.host" -}}
  {{- end -}}
  {{- if and (not .Values.redis.enabled)      (not .Values.redis.external.host)      -}}
    {{- fail "redis.enabled=false requires redis.external.host" -}}
  {{- end -}}
  {{- if and (not .Values.redpanda.enabled)   (not .Values.redpanda.external.brokers) -}}
    {{- fail "redpanda.enabled=false requires redpanda.external.brokers" -}}
  {{- end -}}
{{- end -}}
