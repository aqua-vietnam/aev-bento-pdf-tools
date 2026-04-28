{{/*
Expand the name of the AEV-PDF
*/}}
{{- define "AEV-PDF.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "AEV-PDF.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "AEV-PDF.labels" -}}
helm.sh/chart: {{ include "AEV-PDF.chart" . }}
{{ include "AEV-PDF.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "AEV-PDF.selectorLabels" -}}
app.kubernetes.io/name: {{ include "AEV-PDF.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
