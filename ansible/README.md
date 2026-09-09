# Ansible dev environment playbook

`playbook.yml` provisions host-level tools this repo's notebooks and scripts
need but that aren't already covered by a Dockerfile, docker-compose, or a
Python `requirements.txt` — things like the AWS CLI, AWS SAM CLI, Docker, and
`unzip`.

## Prerequisites

Install Ansible on the machine that will run the playbook (not inside a
container — this playbook targets `localhost` directly):

```bash
# Debian/Ubuntu
sudo apt-get update && sudo apt-get install -y ansible

# macOS
brew install ansible

# or via pip
pip install ansible
```

## Running the playbook

From the repository root:

```bash
ansible-playbook ansible/playbook.yml --ask-become-pass
```

`--ask-become-pass` prompts for your sudo password, since the playbook
installs system packages (`become: true`).

The playbook is idempotent — tasks check for existing installations first,
so it's safe to re-run any time you pull changes that add new tooling
requirements.

## What it installs

- **Docker** (`docker.io`) — used by `chapter 6/lambda-deployment` to build
  the Lambda container image locally
- **unzip** — needed to extract the AWS CLI / SAM CLI installers
- **AWS CLI v2** — used by `chapter 6/lambda-deployment/deploy.sh`
  (`aws sts get-caller-identity`)
- **AWS SAM CLI** — used by `chapter 6/lambda-deployment/deploy.sh`
  (`sam build`, `sam deploy`)
- **tmux** — terminal multiplexer for running long-lived or background
  sessions during development
- **kubectl** — used by `chapter 6/eks-deployment/deploy.sh` and
  `deploy-cfn.sh` to apply manifests and check rollout/ingress status
- **Helm** — used by both `chapter 6/eks-deployment` scripts to install the
  AWS Load Balancer Controller
- **gettext-base** (`envsubst`) — used by both `chapter 6/eks-deployment`
  scripts to template the `k8s/` manifests before `kubectl apply`

`chapter 6/eks-deployment/deploy.sh` additionally needs
[`eksctl`](https://eksctl.io), which isn't installed by this playbook yet —
`deploy-cfn.sh` doesn't need it (see that folder's README for why).

## Adding a new tool

If you install a new host-level dependency while working in this repo, add
a task for it here in the same change, rather than just noting it in a
README — see the comment above each task for the pattern (a check task,
then an installer task guarded by `when:`).
