# Spring PetClinic — 内网 CI/CD 环境说明

本仓库运行在自建的内网环境，使用 **极狐 GitLab + GitLab Runner（Kubernetes executor）+ Rancher 管理的 RKE2 集群 + Harbor 私有镜像仓库**，实现从提交到上线的完整流水线。

> 上游项目为 [Spring PetClinic](https://github.com/spring-projects/spring-petclinic)，本文件替换了上游 README，用于记录当前环境的实际情况与运维要点。

---

## 1. 技术栈

| 项目 | 版本 / 说明 |
|---|---|
| Spring Boot | 4.1.0（parent） |
| Java | 17（编译与运行均为 17） |
| 构建工具 | Maven 3.9（`pom.xml` 为主；`build.gradle` 保留但未使用） |
| 应用包 | `spring-petclinic-4.0.0-SNAPSHOT.jar`（fat jar） |
| 数据库 | PostgreSQL（`application-postgres.properties`） |

---

## 2. 环境拓扑

```
开发者
  │ git push (SSH 2222)
  ▼
极狐 GitLab  117.50.173.240          项目: root/spring-petclinic
  │ 触发流水线（tag = k8s 的 Runner）
  ▼
GitLab Runner 19.5.1                 kubernetes executor
  │ 在 devops 命名空间创建作业 Pod
  ├─ build / test  容器: maven:3.9-eclipse-temurin-17
  ├─ package       容器: kaniko（镜像构建并直推 Harbor）
  └─ deploy        容器: alpine/k8s（kubectl 部署）
  ▼
Harbor  10.60.78.61:30003            项目: interrogation-services
  │                                    仓库: spring-petclinic
  ▼
RKE2 集群 dev  v1.35.9+rke2r1        单节点 10.60.78.61
  └─ 命名空间 app-dev
       ├─ Deployment petclinic（容器名 workload）
       └─ Deployment demo-db （postgres）
```

### 2.1 GitLab

- 地址：`http://117.50.173.240`（SSH 端口 **2222**），中文界面
- 仓库：`ssh://git@117.50.173.240:2222/root/spring-petclinic.git`，默认分支 `main`（受保护）
- **未启用容器镜像库（Container Registry）**，镜像统一推送到外部 Harbor

### 2.2 GitLab Runner

- 版本 19.5.1，executor 为 `kubernetes`
- 作业 Pod 运行在命名空间 `devops`（早期为 `gitlab-runner`，两个命名空间都做过 RBAC 授权）
- Runner 标签：**`k8s`**（`.gitlab-ci.yml` 中所有作业都通过 `tags: [k8s]` 匹配，标签区分大小写）
- 作业 Pod 内的两个容器：
  - `helper`：跑 git clone、下载/上传 artifacts、注入脚本
  - `build`：执行 `script:` 里的命令
- 已知告警：`won't use informers: not allowed: list on pods`，属于可选优化，不影响运行

### 2.3 Rancher / RKE2 集群

- Rancher 2.14.2 管理，集群名 `dev`，集群 ID `c-m-xxd9csfc`
- Kubernetes `v1.35.9+rke2r1`，CNI `calico`，ingress `ingress-nginx`
- **单节点**：`10-60-78-61` / `10.60.78.61`（同时承担 control-plane 与 worker）
- kubeconfig 由 Rancher 生成，含两个 context：`rancher`（管理集群）与 `dev`（业务集群），`current-context: dev`
  - 查询 `clusters.provisioning.cattle.io` 这类资源必须加 `--context rancher`，业务集群上不存在该资源
- etcd 快照策略：`0 */5 * * *`，保留 5 份

### 2.4 Harbor

- 内网地址：`10.60.78.61:30003`（外部访问 `https://117.50.173.240:30003/harbor/...`）
- 项目：`interrogation-services`
- 镜像：`10.60.78.61:30003/interrogation-services/spring-petclinic:<commit-sha>` 与 `:latest`
- **使用自签证书**，因此：
  - 集群节点需要在 containerd 层信任它（见第 7 节）
  - kaniko 推送时需要 `--skip-tls-verify`

---

## 3. 流水线

配置文件：`.gitlab-ci.yml`，四个阶段，仅在 `main` 分支执行构建与部署。

```
build-app  →  unit-test  →  build-image  →  deploy-app
 (build)       (test)        (package)       (deploy)
```

| 作业 | 阶段 | 镜像 | 作用 |
|---|---|---|---|
| `build-app` | build | `maven:3.9-eclipse-temurin-17` | `mvn package -DskipTests`，产出 `target/*.jar` 作为 artifacts（保留 1 小时） |
| `unit-test` | test | 同上 | `mvn test`，Surefire 报告输出为 JUnit 视图（保留 1 周，失败也保留） |
| `build-image` | package | kaniko | 基于 `Dockerfile` 构建镜像，同时打 commit-sha 与 `latest` 两个 tag，直推 Harbor |
| `deploy-app` | deploy | `alpine/k8s:1.30.4` | `kubectl apply -f k8s/app-dev.yml` → `set image` 为本次 commit tag → `rollout status` 等待就绪（300s 超时） |

### 3.1 Maven 相关约定

- 使用阿里云镜像：`ci/settings.xml`，通过 `-s` 传入（`mirrorOf: *`）
- 本地仓库固定在项目内：`-Dmaven.repo.local=$CI_PROJECT_DIR/.m2/repository`，配合 GitLab cache（key 按分支）复用依赖
- **checkstyle 与 spring-javaformat 当前被跳过**：`-Dcheckstyle.skip=true -Dspring-javaformat.skip=true`
- `pom.xml` 的 nohttp 检查已把 `**/.m2/**/*` 加入排除项（否则会扫描项目内的 Maven 仓库，报上千条违规）

### 3.2 镜像构建（kaniko）

- 构建器镜像走 DaoCloud 代理：`gcr.m.daocloud.io/kaniko-project/executor:v1.23.2-debug`（`gcr.io` 在 Pod 内不可达）
- 必须使用 **debug 版**（含 shell），因为作业里用 `entrypoint: [""]` + shell 脚本
- Harbor 认证通过写 `/kaniko/.docker/config.json` 提供
- 参数：`--skip-tls-verify --skip-tls-verify-pull`（Harbor 自签证书）

### 3.3 部署（deploy-app）

- `KUBE_CONFIG` 变量支持三种形式，脚本自动识别：
  1. **File 类型变量**（推荐）：`$KUBE_CONFIG` 是文件路径，直接 `export KUBECONFIG`
  2. **普通变量 + 明文 YAML**：检测到 `apiVersion:` 即原样写入 `~/.kube/config`
  3. **普通变量 + base64**：去除 `\r\n` 后解码，并校验长度是 4 的倍数
- 部署流程：`apply` 清单 → `kubectl set image` 换成 `:<commit-sha>` → `rollout status --timeout=300s`
- 作业失败即代表 Pod 未就绪，不会出现“假绿灯”

---

## 4. 需要在 GitLab 配置的变量

「设置 → CI/CD → 变量」

| 变量 | 类型 | 必需 | 说明 |
|---|---|---|---|
| `HARBOR_USERNAME` | 变量（掩码） | 是 | Harbor 账号，建议用 robot 账号 |
| `HARBOR_PASSWORD` | 变量（掩码） | 是 | Harbor 密码或 robot token |
| `KUBE_CONFIG` | **文件** | 是 | Rancher 生成的 kubeconfig 原文（多行，不要勾掩码） |

可选覆盖项（优先级高于 `.gitlab-ci.yml` 中的 `variables:`）：`HARBOR_REGISTRY`、`HARBOR_PROJECT`、`HARBOR_IMAGE`、`KANIKO_IMAGE`、`KANIKO_EXTRA_ARGS`、`KUBECTL_IMAGE`、`K8S_NAMESPACE`。

> 提示：`rules` 里请不要写 `&& $VARIABLE` 这类条件。变量缺失时作业不会被创建，且会导致 `needs` 指向不存在的作业，整份 YAML 校验失败（`'xxx' job needs 'yyy' job, but 'yyy' does not exist`）。

---

## 5. Dockerfile

```dockerfile
ARG JRE_IMAGE=docker.m.daocloud.io/library/eclipse-temurin:17-jre

FROM ${JRE_IMAGE}
WORKDIR /app
COPY target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
```

- **只做运行时镜像**：jar 由 `build-app` 作业产出，镜像内不再执行 Maven（避免每次解包 1GB 的 maven 基础镜像并重下依赖）
- 基础镜像走国内源 `docker.m.daocloud.io`（Pod 内无法访问 `index.docker.io`）
- 注意 `WORKDIR /app` 后 `COPY ... app.jar` 落在 `/app/app.jar`，`ENTRYPOINT` 必须写全路径
- `.dockerignore` 排除了 `.git`、`.m2`、`target/classes` 等，但**保留 `target/*.jar`**

---

## 6. Kubernetes 部署清单

文件：`k8s/app-dev.yml`（`kubectl apply -f k8s/app-dev.yml`）

| 资源 | 名称 | 说明 |
|---|---|---|
| Namespace | `app-dev` | 部署目标命名空间 |
| Secret | `demo-db` | postgres 连接信息（`type: servicebinding.io/postgresql`） |
| Service | `demo-db` | 5432 |
| Deployment | `demo-db` | `postgres:18.4`，**未挂持久卷**，Pod 重建数据即丢 |
| Service | `petclinic` | NodePort，80 → 8080 |
| Deployment | `petclinic` | 容器名 `workload`，镜像来自 Harbor，1 副本 |

应用容器的关键配置：

```yaml
env:
  - name: SPRING_PROFILES_ACTIVE
    value: postgres
  - name: POSTGRES_URL
    value: jdbc:postgresql://demo-db:5432/petclinic
  - name: POSTGRES_USER
    value: user
  - name: POSTGRES_PASS
    value: pass
```

说明：

- `application-postgres.properties` 读取的是 `POSTGRES_URL / POSTGRES_USER / POSTGRES_PASS` 三个环境变量，缺失时回落到 `jdbc:postgresql://localhost/petclinic`（表现为 `Connection to localhost:5432 refused`）
- 清单里遗留的 `SERVICE_BINDING_ROOT` 与 `/bindings` 挂载**当前无效**：`pom.xml` 未引入 `spring-cloud-bindings`，绑定不会生效
- `imagePullSecrets: harbor-pull` 需要提前在 `app-dev` 命名空间创建（不由清单管理）：

```bash
kubectl -n app-dev create secret docker-registry harbor-pull \
  --docker-server=10.60.78.61:30003 \
  --docker-username=<user> --docker-password=<pass>
```

---

## 7. 节点与集群的特殊配置

### 7.1 信任 Harbor 自签证书（必须）

RKE2 节点 `/etc/rancher/rke2/registries.yaml`：

```yaml
mirrors:
  docker.io:
    endpoint:
      - https://docker.m.daocloud.io
      - https://docker.1panel.live
configs:
  "10.60.78.61:30003":
    insecureSkipVerify: true
```

```bash
systemctl restart rke2-server
```

等效于 Docker 时代的 `insecure-registries`。**该配置也可以写入 Rancher 的 `Cluster.spec.rkeConfig.registries`**，由 Rancher 下发：

```yaml
spec:
  rkeConfig:
    registries:
      configs:
        "10.60.78.61:30003":
          insecureSkipVerify: true
```

注意：该字段在 Rancher 界面保存时可能被丢弃，导致集群一直处于 `Reconciling / Waiting for plan to be applied`；此时手动改节点文件，或改用 `caBundle` 方式。

### 7.2 docker.io 加速

节点上的镜像拉取（kubelet）走 `registries.yaml` 里的 mirrors（DaoCloud 等），因此 `maven`、`kubectl`、`postgres` 等 Docker Hub 镜像可以正常拉取。**但 Pod 内部的进程（如 kaniko）不走这个加速**，必须显式使用国内代理地址。

---

## 8. 常见故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| 流水线里只有部分作业 | 被 `rules` 条件过滤，作业不存在（不显示为“跳过”） | 去掉 `&& $VARIABLE` 条件，改在脚本里判空并报错 |
| `Yaml 无效` / `needs ... does not exist` | 上游作业被 `rules` 排除 | 同上 |
| `gcr.io ... i/o timeout` | Pod 内无法访问 gcr.io | 使用 `gcr.m.daocloud.io` 代理 |
| `index.docker.io ... i/o timeout`（kaniko） | Pod 内无法访问 Docker Hub | Dockerfile 的 `FROM` 使用 `docker.m.daocloud.io` |
| `x509: certificate signed by unknown authority` | 节点不信任 Harbor 自签证书 | 见 7.1 |
| `401 Unauthorized` | `harbor-pull` 缺失或账号密码错 | 重建 secret，确认命名空间为 `app-dev` |
| `Unable to access jarfile /app.jar` | `WORKDIR /app` 下 jar 实际在 `/app/app.jar` | 修正 `ENTRYPOINT` |
| `Connection to localhost:5432 refused` | 缺 `POSTGRES_*` 环境变量 | 补齐三个变量 |
| `duplicate key ... unique_owner_pet_name` | `data.sql` 非并发安全，多实例同时初始化 | 副本保持 1，或设 `SPRING_SQL_INIT_MODE=never` |
| 部署后超过 5 分钟未就绪 | 镜像拉取/启动失败 | `kubectl describe pod`、`kubectl get events --sort-by=.lastTimestamp` |
| Maven 下载极慢 | 直连 Maven Central | `ci/settings.xml` 阿里云镜像（已配置） |
| kaniko 构建 5-10 分钟 | **解包基础镜像**占绝大部分时间，且无法复用节点缓存 | 基础镜像换小（alpine 版）、传内网 Harbor、`--compressed-caching=false`、提高 Pod CPU |
| etcd 快照很慢 | db 膨胀 / 磁盘 IO 慢 / 与镜像构建争抢磁盘 | 降低频率、确认快照目录在 SSD、必要时 defrag |

---

## 9. 已知限制与后续待办

1. **单副本约束**：应用启动时会执行 `schema.sql` / `data.sql`，该脚本不是并发安全的，多副本启动会撞唯一约束。后续应改用 Flyway/Liquibase 做一次性迁移，应用侧设 `spring.sql.init.mode=never`。
2. **`demo-db` 无持久卷**：Pod 重建数据丢失，重启后可能再次触发初始化问题，需要补 PVC。
3. **checkstyle / spring-javaformat 被跳过**：建议恢复为独立的非阻断作业（或仅在 MR 中执行），而不是长期关闭。
4. **构建速度**：建议把 `eclipse-temurin:17-jre` 同步到 Harbor（内网拉取实测 141ms），并把 `FROM` 指向内网地址。
5. **Rancher 配置下发**：业务集群当前的 `Reconciling` 状态由 `registries` 变更引起，需用 `caBundle` 方式固化，避免下次下发覆盖节点上手写的内容。
6. **日志观测**：kaniko 在 `Unpacking rootfs` 阶段无进度输出，排查时可给 `KANIKO_EXTRA_ARGS` 追加 `--verbosity=debug`。

---

## 10. 常用命令速查

```bash
# 查看流水线相关
kubectl -n devops get pods | grep concurrent        # 作业 Pod
kubectl -n devops logs <pod> -c build --tail=100    # 构建日志

# 部署状态
kubectl -n app-dev get deploy,rs,pod -l app=petclinic
kubectl -n app-dev describe pod -l app=petclinic | tail -30
kubectl -n app-dev logs -f deploy/petclinic
kubectl -n app-dev rollout status deploy/petclinic --timeout=300s

# 手动换镜像 / 扩缩容
kubectl -n app-dev set image deploy/petclinic workload=<harbor>/interrogation-services/spring-petclinic:<sha>
kubectl -n app-dev scale deploy/petclinic --replicas=1

# 节点侧验证镜像能否拉取
crictl pull 10.60.78.61:30003/interrogation-services/spring-petclinic:latest
crictl images | grep spring-petclinic

# Rancher 侧查询集群（必须指定 context）
kubectl --context rancher -n fleet-default get clusters.provisioning.cattle.io dev -o yaml
```
