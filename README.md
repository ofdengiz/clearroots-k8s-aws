# ClearRoots — public HTTPS service on a Terraform-provisioned Kubernetes cluster

Infrastructure-as-code for a small, self-contained public web service: two EC2
nodes bootstrapped into a `kubeadm` cluster, a containerised site running as a
NodePort-backed Deployment, and Caddy terminating TLS at the edge behind a
Route 53 record.

This was the cloud half of a two-site managed-service environment built for the
Algonquin College Computer Systems Technician – Networking capstone
(Jan – Apr 2026). ClearRoots was one of two simulated client tenants. The
cloud site — design, build and operation — was solo work; the on-premises site
was delivered collaboratively and is not part of this repository.

---

## Architecture

```
                    clearroots.omerdengiz.com
                              │
                     Route 53 A record (TTL 300)
                              │
                         Elastic IP
                              │
   ┌──────────────────────────▼──────────────────────────┐
   │  worker node — t3.micro, Ubuntu 22.04               │
   │                                                     │
   │    Caddy :80/:443   TLS terminated + auto-renewed   │
   │         │                                           │
   │         └── reverse_proxy 127.0.0.1:30080           │
   │                        │                            │
   │              NodePort service :30080                │
   │                        │                            │
   │        2 × clearroots-web pods (nginx:alpine)       │
   └─────────────────────────────────────────────────────┘
                              │ 6443
   ┌──────────────────────────▼──────────────────────────┐
   │  master node — control plane, Flannel CNI           │
   │  no public DNS record, no inbound path from the web │
   └─────────────────────────────────────────────────────┘
```

| File | Role |
| --- | --- |
| `main.tf` | EC2 instances, Elastic IP, IAM role/profile, security group |
| `variables.tf` | Inputs — region, AMI, instance type, domain, image, zone ID |
| `route53.tf` | Public A record pointing at the worker's Elastic IP |
| `outputs.tf` | Node addresses, site URL, ready-to-paste SSH commands |
| `s3.tf` | Note on why the state bucket is not managed here |
| `master.sh` | Control-plane bootstrap, CNI, storage class, manifest staging |
| `worker.sh` | Worker bootstrap, cluster join, Caddy install and config |
| `deployment.yaml` / `service.yaml` | Workload and NodePort service |
| `Dockerfile` | `nginx:alpine` image carrying `site/` |
| `site/` | The static page the pods serve |

---

## Decisions worth explaining

**The worker joins the cluster without a distributed SSH key.**
A worker needs the `kubeadm` join token, and the token can only be minted on
the master. Baking a private key into user-data to fetch it would put a
long-lived credential in EC2 metadata and in Terraform state. Instead both
nodes carry an instance profile whose only permission is
`ec2-instance-connect:SendSSHPublicKey`, conditioned on `ec2:osuser` being
`ubuntu`. The worker pushes an ephemeral public key valid for sixty seconds,
pulls the token and CA hash, and joins. Nothing persistent is stored anywhere.

**Ordering is expressed twice, on purpose, and neither is the real fix.**
Terraform already orders the nodes: `worker`'s user-data interpolates
`aws_instance.master.id` and `.private_ip`, which is an implicit dependency.
The explicit `depends_on` only states it for a reader. Neither helps with the
dependency that actually matters — the master *existing* is not the master
*being ready*, and a worker that boots faster than the control plane will fail
its join. That is handled where it belongs, in `worker.sh`, which polls
`kubectl get nodes` until the master reports `Ready` and retries token
retrieval until it returns something. This was the failure that cost the most
time to diagnose: a `terraform apply` that succeeded while the cluster had one
node in it.

**Only the worker gets an Elastic IP.**
The public A record has to be stable, and the worker is the only public entry
point. The master has no public DNS name and nothing routed to it from the
internet. Rebuilding the control plane does not touch DNS.

**Caddy rather than an ALB.**
One node serves the public edge, so a managed load balancer would have added
monthly cost and a second TLS configuration surface for no availability gain
at this size. Caddy obtains and renews certificates automatically and proxies
to the NodePort on loopback.

**The state bucket is created by hand.**
Terraform cannot create the bucket that holds its own state on the first run.
Rather than hide that with a bootstrap module, the bucket is made once
manually and `backend.hcl` points at it — see `s3.tf`.

---

## Running it

Prerequisites: an AWS account, a Route 53 hosted zone you control, an EC2 key
pair, an S3 bucket for state, and a container image built from `site/`.

```bash
docker build -t <your-registry>/clearroots-web:latest .
docker push  <your-registry>/clearroots-web:latest

cp backend.hcl.example backend.hcl        # fill in your bucket
terraform init -backend-config=backend.hcl
terraform apply -var="hosted_zone_id=<your zone id>"
```

Then apply the manifests the bootstrap staged on the master:

```bash
kubectl apply -f /home/ubuntu/clearroots/
```

`terraform output website_url` prints the address once DNS propagates.

Security group ingress: `22` (SSH), `80`/`443` (public HTTPS), `6443`
(Kubernetes API), and all traffic from the group to itself for pod networking.

---

## Known limits

This was built to a course budget and reads that way in places, which is worth
stating plainly rather than leaving for a reviewer to find:

- **`t3.micro` is below the `kubeadm` minimum** of 2 CPUs and 2 GB, so both
  bootstrap scripts pass `--ignore-preflight-errors=All`. It runs, but it is
  not a sizing anyone should copy.
- **Single control plane, single worker.** No HA, and losing the worker takes
  the site down until the Elastic IP is re-associated.
- **The AMI is pinned to a `us-east-1` Ubuntu 22.04 image ID.** Another region
  needs a different one, or an `aws_ami` data source.
- **No CI.** Images were built and pushed by hand.

## Not in this repository

The EC2 private key, the Terraform state backend configuration, and the
coursework documents and team deliverables that surrounded the project. The
history here starts at the published state of the code; it is not a rewrite of
an earlier repository.

## Licence

MIT — see [LICENSE](LICENSE).
