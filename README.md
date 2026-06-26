# Tienda del Chancho Pedro — Despliegue en AWS EKS

Aplicación CRUD de productos para una tienda de productos de la granja (verduras, hortalizas,
huevos y miel), desplegada en un clúster **AWS EKS** con CI/CD automatizado mediante **GitHub
Actions**. Proyecto de la Evaluación Parcial N°3 — *Introducción a Herramientas Devops* (ISY1101).

> **Estado:** ✅ Desplegado y funcionando en AWS EKS (clúster `tienda-eks`, namespace `tienda`).
> **URL pública:** http://a34e75236358f42498baab67bc16ca77-605256121.us-east-1.elb.amazonaws.com
> _(la URL del ELB se regenera cada vez que se recrea el Service en una nueva sesión del lab)._

## Arquitectura

```
                 Internet
                    │
            ┌───────▼────────┐   Classic ELB (público)
            │  tienda-frontend│  Service type LoadBalancer
            │  (nginx, 2 pods)│
            └───────┬────────┘
                    │ proxy /api/ → http://tienda-backend:3001  (DNS interno)
            ┌───────▼────────┐
            │  tienda-backend │  Service ClusterIP
            │ (Node/Express,  │  2 pods + HPA
            │     2 pods)     │
            └───────┬────────┘
                    │ mysql://tienda-db:3306  (DNS interno)
            ┌───────▼────────┐
            │   tienda-db     │  Service headless
            │   (MySQL 8)     │
            └────────────────┘

         Clúster EKS (namespace: tienda) · 2 nodos t3.medium · us-east-1
```

**Flujo CI/CD:** `git push` (a `main` o `dev`) → GitHub Actions → build imágenes Docker → push a
Amazon ECR → `kubectl apply` + `set image` en EKS → rollout.

## Componentes

| Servicio | Tecnología | Puerto | Service | Réplicas |
|----------|-----------|--------|---------|----------|
| `tienda-frontend` | nginx + HTML/JS estático | 80 | LoadBalancer (ELB público) | 2 (HPA 2–6) |
| `tienda-backend` | Node.js + Express + mysql2 | 3001 | ClusterIP | 2 (HPA 2–10) |
| `tienda-db` | MySQL 8 | 3306 | Headless (ClusterIP None) | 1 |

El frontend hace de proxy: las llamadas a `/api/` se redirigen al backend dentro del clúster
(ver `frontend/default.conf`). El backend expone un CRUD en `/api/productos` y un healthcheck en
`/api/health`.

## Estructura del repositorio

```
.
├── frontend/                 # nginx + index.html + app.js (CRUD) + img/ + Dockerfile
├── backend/                  # API Express (server.js) + Dockerfile
├── db/                       # MySQL 8 + init.sql (esquema + seed) + Dockerfile
├── k8s/                      # Manifiestos de Kubernetes
│   ├── namespace.yaml
│   ├── mysql-secret.yaml     # password de MySQL (Secret)
│   ├── mysql-deployment.yaml / mysql-service.yaml
│   ├── backend-deployment.yaml / backend-service.yaml / backend-hpa.yaml
│   └── frontend-deployment.yaml / frontend-service.yaml / frontend-hpa.yaml
└── .github/workflows/
    └── deploy-eks.yml        # Pipeline CI/CD
```

## Requisitos

- Cuenta **AWS Academy Learner Lab** (laboratorio iniciado).
- **AWS CLI v2**, **kubectl**, **Docker Desktop**, **git**.
- Repositorios ECR creados: `tienda-frontend`, `tienda-backend`, `tienda-db`.

## Despliegue (resumen)

> Guía paso a paso completa en `EP3_PLAN_ENCARGO.md` (en la carpeta del curso).

1. **Credenciales** (perfil dedicado del lab):
   ```bash
   export AWS_PROFILE=tienda-lab
   aws sts get-caller-identity        # verificar que es la cuenta del lab
   ```
2. **Reemplazar `ACCOUNT_ID`** por tu número de cuenta en los manifiestos `k8s/*-deployment.yaml`.
3. **Build & push de imágenes a ECR** (primera vez, manual):
   ```bash
   REGISTRY=$ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com
   aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $REGISTRY
   docker build -t $REGISTRY/tienda-frontend:eks-v1 ./frontend && docker push $REGISTRY/tienda-frontend:eks-v1
   docker build -t $REGISTRY/tienda-backend:eks-v1  ./backend  && docker push $REGISTRY/tienda-backend:eks-v1
   docker build -t $REGISTRY/tienda-db:eks-v1       ./db       && docker push $REGISTRY/tienda-db:eks-v1
   ```
   > En Apple Silicon agregar `--platform linux/amd64` a cada `docker build`.
4. **Conectar kubectl al clúster:**
   ```bash
   aws eks update-kubeconfig --region us-east-1 --name tienda-eks --profile tienda-lab
   ```
5. **Aplicar manifiestos:**
   ```bash
   kubectl apply -f k8s/namespace.yaml
   kubectl apply -f k8s/mysql-secret.yaml -f k8s/mysql-deployment.yaml -f k8s/mysql-service.yaml
   kubectl apply -f k8s/backend-deployment.yaml -f k8s/backend-service.yaml
   kubectl apply -f k8s/frontend-deployment.yaml -f k8s/frontend-service.yaml
   ```
6. **Autoscaling** (requiere metrics-server):
   ```bash
   kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
   kubectl apply -f k8s/backend-hpa.yaml -f k8s/frontend-hpa.yaml
   ```
7. **Obtener la URL pública:**
   ```bash
   kubectl get svc tienda-frontend -n tienda   # copiar EXTERNAL-IP (DNS del ELB) al navegador
   ```

## CI/CD (GitHub Actions)

El workflow `.github/workflows/deploy-eks.yml` se dispara con cada `push` a `main` (o manual con
*workflow_dispatch*). Hace: checkout → login AWS/ECR → build & push de las 3 imágenes → configurar
kubeconfig → aplicar manifiestos → `kubectl set image` → `rollout status`.

**Secrets requeridos** (repo → *Settings → Secrets and variables → Actions*):

| Secret | Descripción |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | Credencial del lab (caduca cada sesión) |
| `AWS_SECRET_ACCESS_KEY` | Credencial del lab (caduca cada sesión) |
| `AWS_SESSION_TOKEN` | Token de sesión del lab (caduca cada sesión) |
| `AWS_REGION` | `us-east-1` |
| `EKS_CLUSTER_NAME` | `tienda-eks` |
| `EKS_NAMESPACE` | `tienda` |

> ⚠️ Las credenciales del Learner Lab **caducan al reiniciar el lab**. Hay que actualizar los 3
> primeros secrets en cada sesión, o el deploy falla con `ExpiredToken`.

## Gestión de secrets

- La contraseña de MySQL vive en un `Secret` de Kubernetes (`k8s/mysql-secret.yaml`), consumida
  por el backend vía `secretKeyRef` — nunca en texto plano en los deployments.
- Las credenciales de AWS no están en el código: se inyectan como *GitHub Actions Secrets*.
- `.gitignore` excluye `.env`, `.aws/`, claves y kubeconfig para evitar fugas.

## Validación funcional

```bash
curl http://<EXTERNAL-IP>/api/health      # {"status":"ok",...}
kubectl get pods -n tienda                # front (2), backend (2), db (1) en Running
kubectl get hpa  -n tienda                # targets de CPU reales (no <unknown>)
kubectl delete pod -l app=tienda-backend -n tienda   # self-healing: k8s recrea los pods
```

En el navegador (URL del ELB): **Cargar Productos** lista el seed; crear/editar/eliminar valida el
CRUD completo Front → Back → MySQL.

## Autor

- **Najeeb Escobar Pérez** — trabajo individual (autorizado por el docente).

## Documentación adicional

- [`docs/IE5-secrets.md`](docs/IE5-secrets.md) — gestión de secrets y credenciales.
- [`docs/IE6-logs-metricas.md`](docs/IE6-logs-metricas.md) — análisis de logs, métricas y tiempos.
