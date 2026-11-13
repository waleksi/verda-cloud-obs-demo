# verda-cloud-obs-demo

A small observability stack for batch workloads, running on a single Verda CPU VM. OpenTofu creates the VM,
a bootstrap script installs minikube and Argo CD, and from then on Argo CD deploys everything else from
this repository. The demo workload is a pair of jobs queued by Kueue, watched through metrics, logs and a
Grafana dashboard.

## Set it up

You need [OpenTofu](https://opentofu.org), Verda API credentials and an SSH key pair.

```bash
export VERDA_CLIENT_ID=...
export VERDA_CLIENT_SECRET=...

cd tofu
cp terraform.tfvars.example terraform.tfvars   # set ssh_public_key_path to YOUR public key
tofu init
tofu apply
```

The VM only accepts the key you point it at, so keep the matching private key to log in. The first boot
takes 10 to 15 minutes. Follow it with:

```bash
ssh root@$(tofu output -raw public_ip) tail -f /var/log/bootstrap.log
```

When it finishes, check that everything synced:

```bash
sudo -iu kube kubectl -n argocd get applications   # all Synced / Healthy
```

**An existing VM instead of tofu:** [bootstrap.sh](bootstrap.sh) is plain, idempotent bash for a fresh
Ubuntu 24.04 machine: `ssh root@<ip> 'bash -s' < bootstrap.sh`.

**A fork:** the script and the manifests in `argocd/` name `github.com/waleksi/verda-cloud-obs-demo`
(branch `main`). Replace that URL in `bootstrap.sh` and `argocd/*.yaml`, and push, before you deploy.

### Open the UIs

Port-forward over SSH, then browse to the local address.

```bash
# Argo CD -> https://localhost:8080   user: admin, password: secret argocd-initial-admin-secret
ssh -t -L 8080:localhost:8080 root@<ip> "sudo -iu kube kubectl -n argocd port-forward svc/argocd-server 8080:443"

# Grafana -> http://localhost:3000    user: admin, password: secret grafana in namespace grafana
ssh -t -L 3000:localhost:3000 root@<ip> "sudo -iu kube kubectl -n grafana port-forward svc/grafana 3000:80"
```

## See it working

As soon as Argo CD syncs, two demo Jobs (`apps/kueue-jobs/`, 1 CPU and 1.5 CPU, each running `sleep 600`)
are submitted to the Kueue queue `user-queue`. The queue allows 2 CPUs, and the jobs together need 2.5, so
one runs and the other waits. In Grafana, open **Dashboards → Batch Operations** and watch:

1. **At the start:** the status panel shows 1 admitted and 1 pending. *Running and pending jobs* lists both,
   and the quota gauge reads 50% or 75%, depending on which job was admitted first.
2. **After about 2 minutes:** the alert *Kueue job pending for more than 2 minutes* fires. See it in
   *Pending and firing alerts* on the dashboard, or under **Alerting → Alert rules** in the `alerts` folder.
3. **After 10 minutes:** the first job finishes and the waiting one is admitted. The alert resolves, and
   *Admission wait time* shows how long it waited.

What the dashboard shows:

- **Quota:** CPU used against the queue's 2 CPU limit, as a gauge and over time.
- **Queue state:** admitted vs pending workloads now (*Kueue Status*) and over time (*Workloads over time*),
  and how long workloads wait before being admitted (*Admission wait time*).
- **Jobs:** a live table of running and pending jobs, read straight from the Kubernetes API.
- **Logs:** the Kueue controller's logs, with a *Log level* filter at the top of the dashboard.

The alert fires when any workload has been pending for more than 2 minutes. It only shows in Grafana, as no
notification destination is configured.

### Run the demo again

The Jobs run once. To queue them again, delete them and Argo CD recreates them from git:

```bash
sudo -iu kube kubectl -n default delete job job-1 job-2
```

## Tear it down

```bash
cd tofu
tofu destroy
```

This deletes the VM, the SSH key and the startup script in Verda.

## How it works

```
 tofu apply ──► Verda VM ──► bootstrap.sh ──► minikube + Argo CD
                                                    │ syncs this repo
                    ┌───────────────────────────────┴────────────────────────┐
                    ▼                                                        ▼
        addons (supporting)                                      observability (backend)
  Kueue, metrics-server, kube-state-metrics,               VictoriaMetrics  VictoriaLogs  Grafana
  VM operator, vmagent, vlagent
```

- **Metrics:** `vmagent` scrapes the cluster (nodes, containers, annotated services such as
  kube-state-metrics). A second agent, created by the VictoriaMetrics operator, scrapes anything declared
  with a `ServiceMonitor`, which is how Kueue is picked up. Both write to VictoriaMetrics.
- **Logs:** `vlagent` runs on every node, reads container logs and ships them to VictoriaLogs.
- **Grafana** reads from VictoriaMetrics and VictoriaLogs, and also asks the Kubernetes API directly for
  the live list of Kueue workloads.
- **Kueue** decides when a job may run. The queue allows 2 CPUs in total, so of the two demo jobs
  (1 CPU and 1.5 CPU) only one runs at a time and the other waits. The dashboard and the alert show it.

## Repository layout

```
bootstrap.sh              fresh VM -> minikube + Argo CD
tofu/                     VM, SSH key and startup script
argocd/
  kustomization.yaml      pinned Argo CD install plus the files below
  self.yaml               Argo CD manages itself
  project-*.yaml          Argo CD projects: addons, observability, apps
  applicationset.yaml     one Argo CD app per folder in addons/ and observability/
  apps.yaml               root app that watches apps/
  addons/                 supporting resources
  observability/          the observability backend
apps/                     workloads: <name>.yaml (Application) + <name>/ (its manifests)
```

### Why `addons` and `observability`

- **`addons`** are supporting resources: things that run the cluster, or produce and collect data, but
  that you don't look at directly. Kueue, metrics-server, kube-state-metrics, the VictoriaMetrics
  operator and the two agents live here.
- **`observability`** is the backend: where data is stored and looked at. VictoriaMetrics, VictoriaLogs
  and Grafana.

The split is also an Argo CD project boundary. Each folder name becomes the project, so permissions can
differ per group. A third project, `apps`, is for workloads and is limited to namespaced resources.

Every folder under `addons/` and `observability/` is a small Helm wrapper chart (a `Chart.yaml` that
pulls the upstream chart, plus a `values.yaml`). The ApplicationSet turns each folder into an Argo CD app
named after the folder and installed into a namespace of the same name.

- **Add an addon or backend:** create a folder with a `Chart.yaml` and `values.yaml`, and push.
- **Add a workload:** add `apps/<name>.yaml` (an Application with `project: apps`) and, if needed,
  `apps/<name>/` with its manifests.
- **Add a dashboard:** drop the exported JSON into `argocd/observability/grafana/dashboards/` and push.

## Components

| Component | Why it is here |
|---|---|
| **Argo CD** | Deploys and keeps everything in sync from git, including itself. |
| **Kueue** | Job queueing. Holds the ResourceFlavor, ClusterQueue (2 CPU limit) and LocalQueue. |
| **metrics-server** | Live CPU and memory per pod for `kubectl top` and k9s. |
| **kube-state-metrics** | Turns Kubernetes object state (pods, jobs) into metrics. |
| **VictoriaMetrics operator** | Reads `ServiceMonitor`s and runs a vmagent for them. |
| **vmagent** | Scrapes cluster metrics and writes them to VictoriaMetrics. |
| **vlagent** | Collects container logs from every node and ships them to VictoriaLogs. |
| **VictoriaMetrics** | Stores metrics. |
| **VictoriaLogs** | Stores logs. |
| **Grafana** | Dashboard, alert rule and datasources, all provisioned from git. |

## Design choices

- **A startup script, not Ansible.** The VM is disposable and the host setup is short, so one script gives
  a one-command deploy with no extra tooling.
- **GitOps after bootstrap.** The script only gets Argo CD running. Chart and Argo CD versions are pinned
  in git, so a rebuild reproduces the same stack.
- **Fixed Service names** (`vmsingle`, `vlsingle`) so the agents and Grafana can point at stable URLs.

## Known limitations

- One minikube node, no high availability. Metrics and logs are lost when the VM is recreated.
- Grafana has no persistent storage. Its admin password is regenerated on each Argo CD sync (the chart
  can't look up its existing Secret under Argo CD), so read it from the Secret each time.
- Docker comes from Ubuntu's `docker.io` package and is not version-pinned.
- The VM needs outbound internet access (GitHub, Helm repos, grafana.com plugins).
