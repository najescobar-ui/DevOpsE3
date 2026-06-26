# EP3 — Encargo: runbook para levantar con cli

> Documento "como se hizo" del encargo. 
> AWS Academy, con los valores y comandos reales. App: **Tienda del Chancho Pedro** (CRUD de
> productos de granja) sobre **AWS EKS**.
> Le agreguué los indicadores d ela rúbrica.


## Datos reales del entorno
| Recurso | Valor |
|---------|-------|
| Cuenta AWS (lab) | `256928245427` |
| Región | `us-east-1` |
| Clúster EKS | `tienda-eks` · Kubernetes `1.35` |
| Nodos | node group `tienda-nodes` · 2 × `t3.medium` · AL2023 |
| Cluster IAM role | `arn:aws:iam::256928245427:role/LabRole` |
| Node IAM role | `…/c213729a…-LabEksNodeRole-CoJCgOKW8EFl` |
| VPC | `vpc-088e3ded31444252c` (default) |
| Subredes | `subnet-034894db7589f1098` (1a), `subnet-09ce096e6be5f602e` (1b), `subnet-08f17071c0dfd101a` (1c) |
| Namespace | `tienda` |
| Repo | https://github.com/najescobar-ui/DevOpsE3 (rama por defecto `main`) |
| Perfil CLI | `tienda-lab` · kubeconfig dedicado `~/.kube/config_ev3` (alias `ev3`) |

## 0. Setup
```bash
# Credenciales del lab pegadas bajo [tienda-lab] en ~/.aws/credentials (NO en [default])
export AWS_PROFILE=tienda-lab
aws configure set region us-east-1 --profile tienda-lab
aws sts get-caller-identity            # 256928245427
```

## IE1 — Clúster EKS (por CLI, sin Auto Mode)
> La consola del lab forzaba **EKS Auto Mode** (exigía Node IAM role, sin opción de apagarlo) y
> Auto Mode rompe el `LoadBalancer` porque `LabRole` no tiene sus políticas. Por eso el clúster se
> creó por **CLI**, que NO activa Auto Mode (`computeConfig: null`).

```bash
# Clúster
aws eks create-cluster \
  --name tienda-eks \
  --role-arn arn:aws:iam::256928245427:role/LabRole \
  --resources-vpc-config "subnetIds=subnet-034894db7589f1098,subnet-09ce096e6be5f602e,subnet-08f17071c0dfd101a,endpointPublicAccess=true,endpointPrivateAccess=true"
aws eks wait cluster-active --name tienda-eks

# Node group
NODE_ROLE=arn:aws:iam::256928245427:role/c213729a5401392l15219566t1w256928245-LabEksNodeRole-CoJCgOKW8EFl
aws eks create-nodegroup \
  --cluster-name tienda-eks --nodegroup-name tienda-nodes \
  --node-role "$NODE_ROLE" \
  --subnets subnet-034894db7589f1098 subnet-09ce096e6be5f602e subnet-08f17071c0dfd101a \
  --scaling-config minSize=2,maxSize=3,desiredSize=2 \
  --instance-types t3.medium --ami-type AL2023_x86_64_STANDARD --disk-size 20
aws eks wait nodegroup-active --cluster-name tienda-eks --nodegroup-name tienda-nodes

# kubectl (kubeconfig dedicado para EV3, lo hice porque trabajo con muchos clusteres. Lo dejo por si le sieve a otro)
export KUBECONFIG=~/.kube/config_ev3
aws eks update-kubeconfig --region us-east-1 --name tienda-eks --profile tienda-lab --kubeconfig ~/.kube/config_ev3
kubectl get nodes            # 2 nodos Ready, v1.35.6-eks
```

## IE2 — Despliegue Front + Back + DB
**Fixes aplicados a los manifiestos antes de desplegar:**
- `frontend-service.yaml`: se quitaron las anotaciones del AWS LB Controller → EKS crea un Classic ELB automático.
- 3 `*-deployment.yaml`: imagen apuntando a la cuenta real `256928245427`.
- `server.js`: `DB_HOST = "tienda-db"` (comillas).

```bash
# Repos ECR
for r in tienda-frontend tienda-backend tienda-db; do
  aws ecr create-repository --repository-name "$r" --image-scanning-configuration scanOnPush=true
done

# Build & push (Mac arm64 → forzar amd64 para los nodos x86)
REGISTRY=256928245427.dkr.ecr.us-east-1.amazonaws.com
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "$REGISTRY"
for svc in frontend backend db; do
  docker buildx build --platform linux/amd64 -t "${REGISTRY}/tienda-${svc}:eks-v1" --push "./${svc}"
done
# OJO zsh: usar ${svc} con llaves; "tienda-$svc:eks-v1" activa el modificador :e de zsh.

# Desplegar
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/mysql-secret.yaml -f k8s/mysql-deployment.yaml -f k8s/mysql-service.yaml
kubectl apply -f k8s/backend-deployment.yaml -f k8s/backend-service.yaml
kubectl apply -f k8s/frontend-deployment.yaml -f k8s/frontend-service.yaml

kubectl get pods -n tienda                    # 5 pods Running (2 front, 2 back, 1 db)
kubectl get svc tienda-frontend -n tienda     # EXTERNAL-IP = DNS del ELB → app pública
```
Validado en el navegador y por API: `GET /api/health` → ok; `GET /api/productos` → datos
(Front→Back→MySQL operativo).

## IE3 — Autoscaling (HPA)
```bash
# metrics-server (los HPA quedaban en <unknown> sin él)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system rollout status deployment/metrics-server
kubectl top nodes

# HPA (backend 70% CPU 2–10 · frontend 60% CPU 2–6)
kubectl apply -f k8s/backend-hpa.yaml -f k8s/frontend-hpa.yaml
kubectl get hpa -n tienda                     # targets reales, p.ej. cpu: 1%/70%
```
**Prueba de carga (scale out) — generador in-cluster:**
```bash
kubectl run -n tienda load-gen --image=busybox:1.28 --restart=Never -- /bin/sh -c \
  "for i in \$(seq 1 20); do (while true; do wget -q -O- http://tienda-backend:3001/api/productos >/dev/null 2>&1; done) & done; wait"
kubectl get hpa -n tienda -w                   # subió a cpu 203%/70% → 10 réplicas (máximo)
```
**Scale in:** `kubectl delete pod load-gen -n tienda` → tras la ventana de estabilización (~5 min)
el HPA volvió de **10 → 2** réplicas.

## IE4 — Pipeline CI/CD (GitHub Actions)
```bash
# Repo + secrets (creds del lab + region/cluster/namespace) cargados con gh secret set
# Workflow .github/workflows/deploy-eks.yml: dispara en push a main o dev.
git push origin dev          # dispara el pipeline
```
Flujo del workflow: checkout → login AWS/ECR → **build** 3 imágenes → **push a ECR** → kubeconfig →
`kubectl apply` + **`kubectl set image`** + **`rollout status`** (front, back y db). Resultado real:
run en verde, **15 steps**, **~97 s** total, y los Deployments quedaron con el **tag = SHA del
commit** (deploy automático y trazable). Se demostró varias veces (incluido el rediseño).

## IE5 — Gestión de secrets
- Password de MySQL en un **Secret de Kubernetes** (`mysql-secret`), consumida por `secretKeyRef`
  (no en texto plano en los Deployments).
- Credenciales AWS como **GitHub Actions Secrets** (`${{ secrets.* }}`), enmascaradas.
- `.gitignore` excluye `.env`, `.aws/`, claves y `kubeconfig`. Detalle en `docs/IE5-secrets.md`.

## IE6 — Logs, métricas y tiempos
```bash
kubectl logs -n tienda deploy/tienda-backend   # "escuchando en 3001" + "Pool MySQL inicializado"
kubectl logs -n tienda deploy/tienda-frontend  # nginx 200 a las probes
kubectl logs -n tienda deploy/tienda-db        # MySQL 8.4 "ready for connections"
kubectl top nodes ; kubectl top pods -n tienda # métricas de CPU/memoria
kubectl get events -n tienda --sort-by=.lastTimestamp   # scaling, rolling update, self-healing
```
Tiempos del pipeline: total ~97 s (build front 6 s / back 8 s / db 14 s; apply base 18 s; update
backend 19 s; update frontend 14 s). Análisis completo en `docs/IE6-logs-metricas.md`.

## IE7 — Validación funcional y resiliencia
**CRUD completo (Front→Back→MySQL):**
```bash
URL=http://<EXTERNAL-IP>
curl -s "$URL/api/health"                                   # {"status":"ok",...}
curl -s -X POST "$URL/api/productos" -H "Content-Type: application/json" \
  -d '{"nombre":"Prueba","descripcion":"x","precio":1990,"stock":7}'   # CREATE → id
curl -s "$URL/api/productos/<id>"                           # READ
curl -s -X DELETE "$URL/api/productos/<id>"                 # DELETE → 404 al releer
```

### Prueba de SELF-HEALING (cómo se hizo y por qué funciona)
**Mecanismo:** el backend es un `Deployment` con `replicas: 2`. Kubernetes mantiene ese número
deseado mediante el **controller del ReplicaSet** (loop de reconciliación): si un pod desaparece,
crea uno nuevo automáticamente. Como hay **2 réplicas** + **readiness probe** en `/api/health`, y
el borrado de pods es **graceful** (los viejos siguen atendiendo mientras los nuevos pasan a Ready),
la app **no pierde disponibilidad**.

**Comando usado (matar los pods del backend):**
```bash
kubectl delete pod -n tienda -l app=tienda-backend
```
**Cómo se midió que no hubo caída** — sonda de disponibilidad en paralelo mientras se mataban los pods:
```bash
URL=http://<EXTERNAL-IP>
( for i in $(seq 1 20); do
    echo "[$(date +%H:%M:%S)] $(curl -s -o /dev/null -w '%{http_code}' --max-time 3 $URL/api/health)"
    sleep 1.5
  done ) &
kubectl delete pod -n tienda -l app=tienda-backend
wait
```
**Resultado observado:**
- La sonda devolvió **HTTP 200 de forma continua** (sin un solo error) durante todo el reemplazo.
- `kubectl get pods -n tienda -l app=tienda-backend` mostró **pods nuevos** (nombres distintos,
  AGE bajo) ya en `Running 1/1`.
- En `kubectl get events -n tienda`: `Killing pod tienda-backend-…` seguido de
  `SuccessfulCreate … Created pod tienda-backend-…` (recreación automática).

**Recuperación post-deploy (redeploy sin downtime):** además del self-healing, el `rollout` del
pipeline reemplaza pods de forma **gradual** (rolling update). En los eventos se ve el ReplicaSet
viejo escalando a 0 y el nuevo a 2 con la imagen nueva, manteniendo la URL siempre disponible.

## Rebranding (cambio posterior demostrando el pipeline)
La app se rebrandeó de "Tienda de Perritos" a **"Tienda del Chancho Pedro"** (productos de granja),
con rediseño visual e imágenes en `frontend/img/`, nuevos productos en `db/init.sql` y strings de
código. Cada cambio se subió por **rama feature → `dev` → push**, disparando el pipeline y
redesplegando automáticamente (más evidencia de CI/CD). Identificadores internos no se tocaron
(DB `tienda_perritos`, infra `tienda-*`).

## Flujo de trabajo Git usado
`feature/<caso>` → merge a **`dev`** (push, dispara pipeline) → al final merge **`dev` → `main`**.
Commits explicativos en español. Sin referencias a herramientas de IA en el repo.

## Resumen final
Los **7 indicadores del encargo (IE1–IE7)** quedaron implementados, verificados y documentados, con
la app desplegada en EKS, autoscaling y pipeline CI/CD operativos, y todo consolidado en `main`.
