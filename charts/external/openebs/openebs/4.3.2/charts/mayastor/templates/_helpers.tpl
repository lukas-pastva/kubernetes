{{/* vim: set filetype=mustache: */}}

{{/*
Renders a value that contains template.
Usage:
{{ include "render" ( dict "value" .Values.path.to.the.Value "context" $) }}
*/}}
{{- define "render" -}}
    {{- if typeIs "string" .value }}
        {{- tpl .value .context }}
    {{- else }}
        {{- tpl (.value | toYaml) .context }}
    {{- end }}
{{- end -}}

{{/*
Renders the CORE server init container, if enabled
Usage:
{{ include "base_init_core_containers" . }}
*/}}
{{- define "base_init_core_containers" -}}
    {{- if .Values.base.initCoreContainers.enabled }}
    {{- include "render_init_containers" (dict "value" .Values.base.initCoreContainers.containers "context" $) | nindent 8 }}
    {{- end }}
{{- end -}}

{{/*
Renders the HA NODE AGENT init container, if enabled
Usage:
{{ include "base_init_ha_node_containers" . }}
*/}}
{{- define "base_init_ha_node_containers" -}}
    {{- if .Values.base.initHaNodeContainers.enabled }}
    {{- include "render_init_containers" (dict "value" .Values.base.initHaNodeContainers.containers "context" $) | nindent 8 }}
    {{- end }}
{{- end -}}

{{/*
Renders the base init containers for all deployments, if any
Usage:
{{ include "base_init_containers" . }}
*/}}
{{- define "base_init_containers" -}}
    {{- if .Values.base.initContainers.enabled }}
    {{- include "render_init_containers" (dict "value" .Values.base.initContainers.containers "context" $) | nindent 8 }}
    {{- end }}
    {{- include "jaeger_collector_init_container" . }}
{{- end -}}

{{/*
Renders the jaeger agent init container, if enabled
Usage:
{{ include "jaeger_collector_init_container" . }}
*/}}
{{- define "jaeger_collector_init_container" -}}
    {{- if .Values.base.jaeger.enabled }}
      {{- if .Values.base.jaeger.initContainer }}
      {{- if .Values.base.jaeger.collector }}
      {{- include "render_init_containers" (dict "value" .Values.base.jaeger.collector.initContainer "context" $) | nindent 8 }}
      {{- else }}
        - name: jaeger-probe
          image: busybox:latest
          command: [ 'sh', '-c', 'trap "exit 1" TERM; until nc -vzw 5 -u jaeger-collector:4317; do date; echo "Waiting for jaeger..."; sleep 1; done;' ]
      {{- end }}
      {{- end }}
    {{- end }}
{{- end -}}

{{/*
Renders the csi node init containers, if enabled
Usage:
{{ include "csi_node_init_containers" . }}
*/}}
{{- define "csi_node_init_containers" -}}
    {{- if (.Values.csi.node.initContainers).enabled }}
    {{- include "render_init_containers" (dict "value" .Values.csi.node.initContainers.containers "context" $) | nindent 8 }}
    {{- end }}
{{- end -}}

{{/*
Renders the base image pull secrets for all deployments, if any
Usage:
{{ include "base_pull_secrets" . }}
*/}}
{{- define "base_pull_secrets" -}}
    {{- if (not (empty .Values.image.pullSecrets)) }}
        {{- range .Values.image.pullSecrets | uniq -}}
            {{ nindent 8 "- name:" }} {{ . }}
        {{- end }}
    {{- else -}}
        {{- if .Values.base.imagePullSecrets }}
            {{- if .Values.base.imagePullSecrets.enabled }}
                {{- if (empty .Values.base.imagePullSecrets.secrets) }}
                    {{ nindent 8 "- name: login" }}
                {{- else -}}
                    {{- include "render" (dict "value" .Values.base.imagePullSecrets.secrets "context" $) | nindent 8 }}
                {{- end}}
            {{- end }}
        {{- end }}
    {{- end }}
{{- end -}}

{{/*
Renders the REST server init container, if enabled
Usage:
{{- include "rest_agent_init_container" . }}
*/}}
{{- define "rest_agent_init_container" -}}
    {{- if .Values.base.initRestContainer.enabled }}
    {{- include "render_init_containers" (dict "value" .Values.base.initRestContainer.initContainer "context" $) | nindent 8 }}
    {{- end }}
{{- end -}}

{{/*
Renders the jaeger scheduling rules, if any
Usage:
{{ include "jaeger_scheduling" . }}
*/}}
{{- define "jaeger_scheduling" -}}
    {{- if index .Values "jaeger-operator" "affinity" }}
  affinity:
    {{- include "render" (dict "value" (index .Values "jaeger-operator" "affinity") "context" $) | nindent 4 }}
    {{- end }}
    {{- if index .Values "jaeger-operator" "tolerations" }}
  tolerations:
    {{- include "render" (dict "value" (index .Values "jaeger-operator" "tolerations") "context" $) | nindent 4 }}
    {{- end }}
{{- end -}}

{{/* Generate Core list specification (-l param of io-engine) */}}
{{- define "cpuFlag" -}}
{{- include "coreListUniq" . -}}
{{- end -}}

{{/* Get the number of cores from the coreList */}}
{{- define "coreCount" -}}
{{- include "coreListUniq" . | split "," | len -}}
{{- end -}}

{{- define "logFormat" -}}
{{- if (regexMatch "^((json|pretty|compact))$" .Values.base.logging.format) -}}
    {{- print .Values.base.logging.format -}}
{{- else -}}
    {{- fail "invalid logging format. valid values are json, pretty, compact" -}}
{{- end -}}
{{- end -}}

{{/* Get a list of cores as a comma-separated list */}}
{{- define "coreListUniq" -}}
{{- if .Values.io_engine.coreList -}}
{{- $cores_pre := .Values.io_engine.coreList -}}
{{- if not (kindIs "slice" .Values.io_engine.coreList) -}}
{{- $cores_pre = list $cores_pre -}}
{{- end -}}
{{- $cores := list -}}
{{- range $index, $value := $cores_pre | uniq -}}
{{- $value = $value | toString | replace " " "" }}
{{- if eq ($value | int | toString) $value -}}
{{-   $cores = append $cores $value -}}
{{- end -}}
{{- end -}}
{{- $first := first $cores | required (print "At least one core must be specified in io_engine.coreList") -}}
{{- $cores | join "," -}}
{{- else -}}
{{- if gt 1 (.Values.io_engine.cpuCount | int) -}}
{{- fail ".Values.io_engine.cpuCount must be >= 1" -}}
{{- end -}}
{{- untilStep 1 (add 1 .Values.io_engine.cpuCount | int) 1 | join "," -}}
{{- end -}}
{{- end }}

{{/*
Adds the project domain to labels
Usage:
{{ include "label_prefix" . }}/release: {{ .Release.Name }}
*/}}
{{- define "label_prefix" -}}
    {{ $product := .Files.Get "product.yaml" | fromYaml }}
    {{- print $product.domain -}}
{{- end -}}

{{/*
Creates the tolerations based on the global and component wise tolerations, with early eviction
Usage:
{{ include "_tolerations_with_early_eviction" (dict "template" . "localTolerations" .Values.path.to.local.tolerations) }}
*/}}
{{- define "_tolerations_with_early_eviction" -}}
{{- toYaml .template.Values.earlyEvictionTolerations | nindent 8 }}
{{- if .localTolerations }}
    {{- toYaml .localTolerations | nindent 8 }}
{{- else if .template.Values.tolerations }}
    {{- toYaml .template.Values.tolerations | nindent 8 }}
{{- end }}
{{- end }}


{{/*
Creates the tolerations based on the global and component wise tolerations
Usage:
{{ include "tolerations" (dict "template" . "localTolerations" .Values.path.to.local.tolerations) }}
*/}}
{{- define "tolerations" -}}
{{- if .localTolerations }}
    {{- toYaml .localTolerations | nindent 8 }}
{{- else if .template.Values.tolerations }}
    {{- toYaml .template.Values.tolerations | nindent 8 }}
{{- end }}
{{- end }}

{{/*
Generates the priority class name, with the given `template` and the `localPriorityClass`
Usage:
{{ include "priority_class" (dict "template" . "localPriorityClass" .Values.path.to.local.priorityClassName) }}
*/}}
{{- define "priority_class" -}}
    {{- if typeIs "string" .localPriorityClass }}
        {{- if .localPriorityClass -}}
            {{ printf "%s" .localPriorityClass -}}
        {{- else if .template.Values.priorityClassName -}}
            {{ printf "%s" .template.Values.priorityClassName -}}
        {{- else -}}
            {{ printf "" -}}
        {{- end -}}
    {{- end -}}
{{- end -}}


{{/*
Generates the priority class name, with the given `template` and the `localPriorityClass`, sets to mayastor default priority class
if both are empty
Usage:
{{ include "priority_class_with_default" (dict "template" . "localPriorityClass" .Values.path.to.local.priorityClassName) }}
*/}}
{{- define "priority_class_with_default" -}}
    {{- if typeIs "string" .localPriorityClass }}
        {{- if .localPriorityClass -}}
            {{ printf "%s" .localPriorityClass -}}
        {{- else if .template.Values.priorityClassName -}}
            {{ printf "%s" .template.Values.priorityClassName -}}
        {{- else -}}
            {{ printf "%s-cluster-critical" .template.Release.Name -}}
        {{- end -}}
    {{- end -}}
{{- end -}}

{{/*
    Generate the default StorageClass parameters.
    This is required because StorageClass parameters cannot be patched after creation.
    If the StorageClass already exists, the default StorageClass carries the parameters and values
    of that StorageClass. Else, it carries the default parameters and values.
*/}}
{{- define "storageClass.parameters" -}}
    {{- $scName := index . 0 -}}
    {{- $valuesParams := index . 1 -}}

    {{/* Check to see if a default StorageClass already exists */}}
    {{- $sc := lookup "storage.k8s.io/v1" "StorageClass" "" $scName -}}

    {{- if $sc -}}
        {{/* Existing defaults */}}
        {{ range $param, $val := $sc.parameters }}
{{ $param | quote }}: {{ $val | quote }}
        {{- end -}}

    {{- else -}}
        {{/* Current defaults */}}
        {{ range $param, $val := $valuesParams }}
{{ $param | quote }}: {{ $val | quote }}
        {{- end -}}
    {{- end -}}
{{- end -}}

{{/*
Adds the image prefix to image name
*/}}
{{- define "image_prefix" -}}
    {{ $product := .Files.Get "product.yaml" | fromYaml }}
    {{- print $product.imagePrefix -}}
{{- end -}}

{{/*
Get the Jaeger URL
*/}}
{{- define "jaeger_url" -}}
    {{- if $collector := .Values.base.jaeger.collector }}
        {{- $collector.name }}:{{ $collector.port }}
    {{- else }}
        {{- print "jaeger-collector:4317" -}}
    {{- end }}
{{- end -}}

{{/*
 Create a normalized etcd name based on input parameters
 */}}
{{- define "etcdUrl" -}}
    {{- if eq (.Values.etcd.enabled) false }}
        {{- if .Values.etcd.externalUrl }}
            {{- .Values.etcd.externalUrl }}
        {{- else }}
          {{- fail "etcd.externalUrl must be set" }}
        {{- end }}
    {{- else }}
        {{- .Release.Name }}-etcd:{{ .Values.etcd.service.port }}
    {{- end }}
{{- end }}

{{/*
 Check if etcd is explicitly enabled/disabled or implicitly enabled (for upgrades where enabled key was absent)
 */}}
{{- define "etcdEnabled" -}}
    {{- if eq (.Values.etcd.enabled) false }}
        {{- "false" -}}
    {{- else if eq (.Values.etcd.enabled) true }}
        {{- "true" -}}
    {{- else if .Values.etcd.externalUrl }}
        {{- "false" -}}
    {{- else }}
        {{- "true" -}}
    {{- end }}
{{- end }}

{{/*
Renders init containers. If unset it sets the container image.
*/}}
{{- define "render_init_containers" -}}
    {{- $containers := list }}
    {{- $image := .context.Values.base.initContainers.image }}
    {{- $values_image := .context.Values.image }}
    {{- range .value -}}
        {{ $container := . }}
        {{- if not (hasKey . "imagePullPolicy") }}
            {{- $pullPolicy := $image.pullPolicy | default $values_image.pullPolicy }}
            {{- $_ := set $container "imagePullPolicy" $pullPolicy }}
        {{- end }}
        {{- if or (not $image) (not (hasKey . "image")) }}
            {{- $registry := $image.registry | default $values_image.registry | default "docker.io" }}
            {{- $namespace := $image.namespace | default $values_image.repo }}
            {{- $name := $image.name | default "alpine-sh" }}
            {{- $tag := $image.tag | default "4.1.0" }}
            {{- $_ := set $container "image" (printf "%s/%s/%s:%s" $registry $namespace $name $tag) }}
        {{- end }}
        {{- $containers = append $containers $container }}
    {{- end -}}
    {{- tpl ($containers | toYaml) .context }}
{{- end -}}

{{/*
Get the Events Jetstream Replica Count
*/}}
{{- define "events_replicas" -}}
    {{- if .Values.nats.cluster.enabled }}
        {{- min .Values.nats.cluster.replicas 3 }}
    {{- else }}
        {{- print "1" -}}
    {{- end }}
{{- end -}}
