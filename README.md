# ClearRoots: public HTTPS service on a Terraform-provisioned Kubernetes cluster

Infrastructure-as-code for a small, self-contained public web service: two EC2
nodes bootstrapped into a `kubeadm` cluster, a containerised site running as a
NodePort-backed Deployment, and Caddy terminating TLS at the edge behind a
Route 53 record.

It is the cloud site of a two-site hybrid managed-service environment, built
for the Algonquin College capstone (Jan – Apr 2026) for ClearRoots, one of two
client organizations. The cloud site was designed, built and operated end to
end; the on-premises site was delivered with the team.

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
   │  worker node: t3.micro, Ubuntu 22.04                │
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
   │  master node: control plane, Flannel CNI            │
   │  no public DNS record, no inbound path from the web │
   └─────────────────────────────────────────────────────┘
```

| File | Role |
| --- | --- |
| `main.tf` | EC2 instances, Elastic IP, IAM role/profile, security group |
| `variables.tf` | Inputs: region, AMI, instance type, domain, image, zone ID |
| `route53.tf` | Public A record pointing at the worker's Elastic IP |
| `outputs.tf` | Node addresses, site URL, ready-to-paste SSH commands |
| `s3.tf` | Note on why the state bucket is not managed here |
| `master.sh` | Control-plane bootstrap, CNI, storage class, manifest staging |
| `worker.sh` | Worker bootstrap, cluster join, Caddy install and config |
| `deployment.yaml` / `service.yaml` | Workload and NodePort service |
| `Dockerfile` | `nginx:alpine` image carrying `site/` |
| `site/` | The static page the pods serve |

---

## Design decisions

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
dependency that actually matters. The master *existing* is not the master
*being ready*, and a worker that boots faster than the control plane will fail
its join. That is handled where it belongs, in `worker.sh`, which polls
`kubectl get nodes` until the master reports `Ready` and retries token
retrieval until it returns something.

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
The bucket is made once, `backend.hcl` points at it, and `s3.tf` records
the step.

**Sized for a demonstration.**
Both nodes are `t3.micro`, below the `kubeadm` minimum of 2 CPUs and 2 GB, so
the bootstrap passes `--ignore-preflight-errors=All`. A production build would
use larger nodes, a highly available control plane or EKS, an `aws_ami` data
source instead of the pinned `us-east-1` image, and a CI pipeline for the
image.

---

## Deploy

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

## Licence

MIT. See [LICENSE](LICENSE).
