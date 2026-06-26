# IE6 — Análisis de logs, métricas y tiempos

Evidencias de observabilidad del clúster `tienda-eks` (namespace `tienda`, región `us-east-1`).
Los datos se obtienen con `kubectl` (metrics-server) y desde GitHub Actions.

## 1. Métricas de recursos

### Nodos (`kubectl top nodes`)
| Nodo | CPU | Memoria |
|------|-----|---------|
| ip-172-31-21-227 | 38m (1%) | 1011Mi (30%) |
| ip-172-31-91-140 | 25m (1%) | 564Mi (17%) |

El clúster opera holgado en reposo: CPU ~1% y memoria 17–30% en cada `t3.medium`.

### Pods (`kubectl top pods -n tienda`)
| Pod | CPU | Memoria |
|-----|-----|---------|
| tienda-backend (×2) | 1m | 21Mi |
| tienda-db | 7m | 433Mi |
| tienda-frontend (×2) | 1m | 3Mi |

El backend en reposo consume 1m de CPU (request = 100m), muy por debajo del umbral del HPA (70%).
La base de datos es la que más memoria usa (MySQL 8.4), coherente con su buffer pool.

### Autoscaling (`kubectl get hpa -n tienda`)
| HPA | Target | Min | Max | Réplicas |
|-----|--------|-----|-----|----------|
| tienda-backend-hpa | cpu 1%/70% | 2 | 10 | 2 |
| tienda-frontend-hpa | cpu 2%/60% | 2 | 6 | 2 |

Durante la prueba de carga el backend llegó a **cpu 203%/70%** y escaló a **10 réplicas** (máximo);
al cortar la carga volvió a **2** tras la ventana de estabilización (~5 min).

## 2. Análisis de logs

### Backend (`kubectl logs deploy/tienda-backend`)
```
Servidor backend escuchando en puerto 3001
Pool de conexiones MySQL inicializado.
```
Arranque limpio: el servidor Express escucha en el 3001 y el pool de conexiones a MySQL se
inicializa sin errores → la conectividad Back → DB (`tienda-db:3306`) está operativa.

### Frontend (`kubectl logs deploy/tienda-frontend`)
```
"GET / HTTP/1.1" 200 3815 "-" "kube-probe/1.35"
```
nginx responde `200` a las readiness/liveness probes (`kube-probe`). Sirve los 3815 bytes del
`index.html` correctamente.

### Base de datos (`kubectl logs deploy/tienda-db`)
```
[InnoDB] InnoDB initialization has ended.
/usr/sbin/mysqld: ready for connections. Version: '8.4.10' port: 3306
```
MySQL 8.4 quedó `ready for connections` en el 3306. El `init.sql` sembró la tabla `productos`.

### Eventos relevantes (`kubectl get events -n tienda`)
- **Rolling update (deploy del pipeline)**: `Scaled up replica set tienda-frontend-848988df5c
  from 1 to 2` / `Scaled down ...-66bdd7f846 from 2 to 1 ... to 0`. Kubernetes reemplazó los pods
  con la imagen nueva (`tienda-frontend:5d6af2d`) de forma gradual → **sin downtime**.
- **Self-healing (IE7)**: `Killing pod tienda-backend-...` seguido de `SuccessfulCreate ...
  Created pod tienda-backend-6fd5fcbf89-{7rxlv,rvd7t}`. Al eliminar los pods, el ReplicaSet creó
  reemplazos automáticamente.

## 3. Tiempos del pipeline CI/CD (GitHub Actions)

Run `28219089489` (push a `dev`), conclusión **success**. Duración total: **~97 s**.

| Step | Duración |
|------|----------|
| Build & push FRONTEND | 6 s |
| Build & push BACKEND | 8 s |
| Build & push DB | 14 s |
| Configurar kubeconfig EKS | 6 s |
| Aplicar manifests base (ns, secret, DB) | 18 s |
| Actualizar BACKEND (set image + rollout) | 19 s |
| Actualizar FRONTEND (set image + rollout) | 14 s |
| Aplicar HPA | 2 s |

**Lectura:** el grueso del tiempo está en los `rollout status` (esperar a que los pods nuevos
queden Ready) y en el build de la imagen de la DB (la más pesada). El pipeline completo
build → push → deploy tarda ~1.5 min, adecuado para despliegue continuo.

## 4. Conclusiones

- El sistema arranca sin errores en las 3 capas (front, back, db) y la comunicación interna por
  DNS de Kubernetes (`tienda-backend:3001`, `tienda-db:3306`) funciona.
- El autoscaling responde a la carga real (scale out a 10, scale in a 2) según el umbral de CPU.
- Los despliegues son graduales (rolling update) y el clúster se autorecupera ante la pérdida de
  pods, todo sin pérdida de disponibilidad.
- Los tiempos del pipeline son bajos y consistentes (~97 s end-to-end).
