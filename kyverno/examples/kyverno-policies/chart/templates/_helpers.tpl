{{/*
Common labels.
*/}}
{{- define "kyverno-policies.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/version: {{ .Chart.Version | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Rule context that exposes the chart's excluded namespaces as a Kyverno variable.
The braces of Kyverno's own variable syntax are quoted so that Helm leaves them
for Kyverno to evaluate at admission time.
*/}}
{{- define "kyverno-policies.namespaceExclusionContext" -}}
- name: excludedNamespaces
  variable:
    value: {{ .Values.excludedNamespaces | toJson }}
{{- end -}}

{{/*
Precondition that skips resources in the excluded namespaces.
*/}}
{{- define "kyverno-policies.namespaceExclusionPrecondition" -}}
- key: {{ "{{ request.namespace || 'default' }}" | quote }}
  operator: AnyNotIn
  value: {{ "{{ excludedNamespaces }}" | quote }}
{{- end -}}
