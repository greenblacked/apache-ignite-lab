{{/* Base name, overridable with nameOverride/fullnameOverride. */}}
{{- define "ignite-lab.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ignite-lab.fullname" -}}
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

{{- define "ignite-lab.headless" -}}
{{- printf "%s-headless" (include "ignite-lab.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ignite-lab.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "ignite-lab.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "ignite-lab.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ignite-lab.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Every pod's stable DNS name, used both for Ignite's node finder and for the
metastorage group passed to "cluster init".
*/}}
{{- define "ignite-lab.nodeNames" -}}
{{- $full := include "ignite-lab.fullname" . -}}
{{- $names := list -}}
{{- range $i := until (int .Values.replicaCount) -}}
{{- $names = append $names (printf "%s-%d" $full $i) -}}
{{- end -}}
{{- join "," $names -}}
{{- end -}}
