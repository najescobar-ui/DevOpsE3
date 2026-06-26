# IE5 — Gestión de secrets y credenciales

El proyecto separa los datos sensibles del código en tres niveles, sin exponer ninguna
credencial en el repositorio.

## 1. Secret de Kubernetes (password de MySQL)

La contraseña de MySQL **no** está escrita en los Deployments. Vive en un `Secret` de Kubernetes
(`k8s/mysql-secret.yaml`), codificada en base64:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mysql-secret
  namespace: tienda
type: Opaque
data:
  MYSQL_ROOT_PASSWORD: YWRtaW4xMjM=
```

Tanto la base de datos como el backend la consumen por referencia (`secretKeyRef`), nunca como
texto plano:

```yaml
# mysql-deployment.yaml y backend-deployment.yaml
env:
  - name: MYSQL_ROOT_PASSWORD          # (DB)
    valueFrom:
      secretKeyRef:
        name: mysql-secret
        key: MYSQL_ROOT_PASSWORD
  - name: DB_PASSWORD                   # (backend)
    valueFrom:
      secretKeyRef:
        name: mysql-secret
        key: MYSQL_ROOT_PASSWORD
```

Verificación de que el Secret existe y el valor no aparece en claro:
```bash
kubectl get secret mysql-secret -n tienda
# NAME           TYPE     DATA   AGE
# mysql-secret   Opaque   1      ...
```

> Nota: un `Secret` de Kubernetes guarda el valor en base64 (no cifrado en reposo por defecto en
> EKS sin KMS). La buena práctica aplicada aquí es **desacoplar** el secreto del manifiesto del
> Deployment y referenciarlo, de modo que el valor no se repita ni quede hardcodeado en el código
> de la aplicación.

## 2. Credenciales de AWS en el pipeline (GitHub Actions Secrets)

Las credenciales de AWS **no** están en el repositorio. Se cargan como *GitHub Actions Secrets*
(Settings → Secrets and variables → Actions) y el workflow las inyecta con `${{ secrets.* }}`:

| Secret | Uso |
|--------|-----|
| `AWS_ACCESS_KEY_ID` | autenticación del runner contra AWS |
| `AWS_SECRET_ACCESS_KEY` | idem |
| `AWS_SESSION_TOKEN` | token de sesión del lab (temporal) |
| `AWS_REGION` | `us-east-1` |
| `EKS_CLUSTER_NAME` | `tienda-eks` |
| `EKS_NAMESPACE` | `tienda` |

```yaml
# .github/workflows/deploy-eks.yml
- name: Configurar credenciales AWS
  uses: aws-actions/configure-aws-credentials@v4
  with:
    aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
    aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
    aws-region: ${{ secrets.AWS_REGION }}
    aws-session-token: ${{ secrets.AWS_SESSION_TOKEN }}
```

GitHub enmascara automáticamente estos valores en los logs del workflow (aparecen como `***`).

> Las credenciales del laboratorio AWS Academy **caducan en cada sesión**, por lo que
> `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` y `AWS_SESSION_TOKEN` deben actualizarse al
> reiniciar el lab, o el deploy falla con `ExpiredToken`.

## 3. Credenciales locales fuera del repositorio (`.gitignore`)

El `.gitignore` versionado excluye cualquier archivo con credenciales o estado local:

```gitignore
.aws/
*.pem
*.key
.env
.env.*
*credentials*
kubeconfig
*.kubeconfig
```

Las credenciales del lab se usan localmente desde un **perfil dedicado** de la AWS CLI
(`[tienda-lab]` en `~/.aws/credentials`, fuera del repo) para no mezclarlas con otros perfiles
ni subirlas nunca al control de versiones.

## 4. Resumen de buenas prácticas aplicadas

- Ningún secreto ni credencial está hardcodeado en el código de la aplicación.
- La password de MySQL se gestiona con un `Secret` de Kubernetes y se referencia con `secretKeyRef`.
- Las credenciales de AWS viven en GitHub Secrets, enmascaradas y fuera del repo.
- `.gitignore` impide subir credenciales o `kubeconfig` locales.
- Uso de un perfil de AWS CLI aislado para el laboratorio.

### Mejora futura (opcional)
Mover también `DB_USER`, `DB_NAME` y `DB_PORT` al `Secret`/`ConfigMap` y, para un entorno
productivo, integrar **AWS Secrets Manager** o **External Secrets Operator** con cifrado KMS.
