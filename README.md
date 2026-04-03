# 📜 Monitoreo de Certificados TLS en OpenShift con x509-certificate-exporter + Grafana

Guía completa para monitorear expiración de certificados TLS en OpenShift usando:

* Prometheus User Workload Monitoring
* x509-certificate-exporter
* Thanos Querier
* Grafana

---

# 📐 Arquitectura

```
[Secrets TLS en todos los NS]
        ↓
[x509-certificate-exporter]
        ↓
[ServiceMonitor]
        ↓
[Prometheus User Workload]
        ↓
[Thanos Querier]
        ↓
[Grafana]
        ↓
[Dashboard certificados]
```

---

# 🧩 Prerrequisitos

* OpenShift 4.20
* Helm instalado
* Acceso cluster-admin
* jq (opcional)

---

# 1️⃣ Habilitar User Workload Monitoring

```bash
oc -n opensshift-monitoring edit configmap cluster-monitoring-config
```

Debe contener:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: opensshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
```

Verificar:

```bash
oc get pods -n openshift-user-workload-monitoring
```

---

# 2️⃣ Crear proyecto exporter

```bash
oc new-project exportador-certificado
```

---

# 3️⃣ Instalar x509-certificate-exporter

```bash
helm repo add enix https://charts.enix.io
helm repo update
```

Crear values.yaml:

```bash
cat <<EOF > x509-values.yaml
secretsExporter:
  enabled: true

podMonitor:
  enabled: false

serviceMonitor:
  enabled: true
  additionalLabels:
    openshift.io/cluster-monitoring: "true"

daemonSets: {}

securityContext:
  runAsNonRoot: true
  runAsUser: 65534

rbac:
  create: true
  serviceAccountName: x509-certificate-exporter
EOF
```

Instalar:

```bash
helm install x509-certificate-exporter enix/x509-certificate-exporter \
  -n exportador-certificado \
  -f x509-values.yaml
```

---

# 4️⃣ Permisos OpenShift

```bash
oc adm policy add-cluster-role-to-user view \
system:serviceaccount:exportador-certificado:x509-certificate-exporter
```

```bash
oc adm policy add-scc-to-user nonroot \
system:serviceaccount:exportador-certificado:x509-certificate-exporter
```

---

# 5️⃣ Verificar scraping

```bash
oc get servicemonitor -n exportador-certificado
```

```bash
oc port-forward svc/prometheus-user-workload 9090:9090 \
-n openshift-user-workload-monitoring
```

Abrir:

```
http://localhost:9090/targets
```

Verificación CLI:

```bash
oc exec -n openshift-user-workload-monitoring \
$(oc get pod -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus -o name | head -1) \
-- curl -s http://localhost:9090/api/v1/targets \
| jq '.data.activeTargets[] | {job: .labels.job, health: .health}'
```

---

# 6️⃣ Instalar Grafana

```bash
oc new-project grafana-custom
```

```bash
helm repo add grafana-community https://grafana-community.github.io/helm-charts
```

```bash
helm install my-grafana grafana-community/grafana --namespace grafana-custom
```

---

# 6.1 Eliminar securityContext (OpenShift)

```bash
oc patch deployment/grafana \
--type='json' \
-p='[
{"op": "remove", "path": "/spec/template/spec/securityContext/fsGroup"},
{"op": "remove", "path": "/spec/template/spec/securityContext/runAsGroup"},
{"op": "remove", "path": "/spec/template/spec/securityContext/runAsUser"}
]'
```

---

# 6.2 ServiceAccount Grafana

```bash
oc create serviceaccount grafana-datasource
```

```bash
oc adm policy add-cluster-role-to-user cluster-monitoring-view \
system:serviceaccount:grafana-custom:grafana-datasource
```

Token:

```bash
oc create token grafana-datasource -n grafana-custom --duration=8760h
```

---

# 6.3 Crear Route Grafana

```bash
oc create route edge grafana-custom-route \
--service=grafana \
--hostname=grafana-custom-route-grafana-custom.apps-crc.testing \
--port=service \
--insecure-policy=Allow \
-n grafana-custom
```

---

# 6.4 Reset password admin

```bash
oc exec $(oc get po -n grafana-custom --no-headers| awk '{print $1}') \
-n grafana-custom -- \
bash -c "grafana-cli admin reset-admin-password admin123"
```

---

# 6.5 Obtener URL Thanos

```bash
oc get route thanos-querier -n openshift-monitoring
```

---

# 6.6 Crear datasource vía API

```bash
TOKEN=$(oc create token grafana-datasource -n grafana-custom --duration=8760h)

GRAFANA_URL=http://$(oc get route grafana-custom-route \
-n grafana-custom \
-o jsonpath='{.spec.host}')

curl -X POST "$GRAFANA_URL/api/datasources" \
-H "Content-Type: application/json" \
-u "admin:admin123" \
-d '{"name":"Prometheus-OCP","type":"prometheus","url":"https://thanos-querier-openshift-monitoring.apps-crc.testing","access":"proxy","basicAuth":false,"jsonData":{"httpHeaderName1":"Authorization","tlsSkipVerify":true},"secureJsonData":{"httpHeaderValue1":"Bearer '"$TOKEN"'"}}'
```

---

# 7️⃣ Dashboard

Importar desde Grafana.com:

```
Dashboard ID: 13922
curl -s https://grafana.com/api/dashboards/13922/revisions/latest/download \
| jq '{dashboard: ., overwrite: true, inputs: []}' \
| curl -X POST "$GRAFANA_URL/api/dashboards/import" \
  -H "Content-Type: application/json" \
  -u "admin:admin123" \
  -d @-```
---

# 📊 Queries útiles

### Días para vencer

```
(x509_cert_not_after - time()) / 86400
```

### Certificados vencidos

```
x509_cert_expired == 1
```

### Vencen en menos de 30 días

```
((x509_cert_not_after - time()) / 86400) < 30
```

---

# ✅ Resultado

* Monitoreo automático de certificados TLS
* Alertas por expiración
* Dashboard centralizado
* Integración con Prometheus OpenShift

---

# 🏁 Flujo final

```
OpenShift Secrets
        ↓
x509 exporter
        ↓
ServiceMonitor
        ↓
Prometheus user workload
        ↓
Thanos querier
        ↓
Grafana datasource
        ↓
Dashboard certificados
```
