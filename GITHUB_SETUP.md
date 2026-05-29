# GitHub Setup — Creating and Pushing the Kamaji Lab Repo

## Step 1 — Create the repo on GitHub

1. Go to [github.com/new](https://github.com/new)
2. Fill in:
   - **Repository name:** `kamaji-lab`
   - **Description:** `Multi-tenant Kubernetes platform lab — K3s, Kamaji, Capsule, Kamaji Console on macOS`
   - **Visibility:** Public or Private (your choice)
   - ❌ Do NOT initialise with README, .gitignore, or licence — we'll push our own
3. Click **Create repository**
4. Copy the repo URL shown — it will be:
   `https://github.com/<your-username>/kamaji-lab.git`

---

## Step 2 — Prepare the local directory

Unzip the downloaded `kamaji-lab.zip` if you haven't already, or navigate to your existing directory:

```bash
cd ~/Documents/Dev-Tech-Docs-and-Guides\ /How-To-Docs/Kamaji/kamaji-lab
ls
# README.md  docs/  scripts/  manifests/
```

Move the main guide into the docs directory:

```bash
mkdir -p docs/images
mv kamaji-overview.md docs/
```

Take a screenshot of the Kamaji Console dashboard and save it:

```bash
# Save your Kamaji Console screenshot as:
cp ~/Downloads/kamaji-console-screenshot.png docs/images/kamaji-console-dashboard.png
```

---

## Step 3 — Initialise the git repo

```bash
cd ~/Documents/Dev-Tech-Docs-and-Guides\ /How-To-Docs/Kamaji/kamaji-lab

git init
git config user.name "Simon Day"
git config user.email "your@email.com"   # replace with your GitHub email
```

Create a `.gitignore`:

```bash
cat > .gitignore << 'EOF'
# Kubeconfigs — never commit these
*.kubeconfig
kubeconfig
.kube/

# macOS
.DS_Store
.AppleDouble

# Editor
.vscode/
*.swp

# Secrets
*secret*
*password*
EOF
```

---

## Step 4 — Initial commit

```bash
git add .
git status   # review what will be committed

git commit -m "Initial commit: Kamaji platform engineering lab

Complete guide and scripts for running K3s + Kamaji + Capsule + Kamaji Console
on macOS M3 using Lima. Includes:
- Full setup guide (~3000 lines, all errors and fixes documented)
- Automation scripts for Lima, MetalLB, Kamaji, Capsule, Console, worker nodes
- Shell helpers for kubectl context switching
- Demo manifests for tenant control planes
- Tested on macOS 15, Apple M3, Lima 2.1.1, K3s v1.35.5, Kamaji v0.x"
```

---

## Step 5 — Push to GitHub

```bash
git remote add origin https://github.com/<your-username>/kamaji-lab.git
git branch -M main
git push -u origin main
```

GitHub will prompt for credentials. Use your GitHub username and a **Personal Access Token** (not your password):

1. Go to GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Generate new token with `repo` scope
3. Use the token as your password when prompted

Or set up SSH (recommended for regular use):

```bash
# If you have SSH set up with GitHub already
git remote set-url origin git@github.com:<your-username>/kamaji-lab.git
git push -u origin main
```

---

## Step 6 — Verify

```bash
# Check everything pushed
git log --oneline
git status

# Open in browser
open https://github.com/<your-username>/kamaji-lab
```

---

## Step 7 — Ongoing updates

As you continue the lab (Cilium, Kargo, etc.), update the doc and push:

```bash
cd ~/Documents/Dev-Tech-Docs-and-Guides\ /How-To-Docs/Kamaji/kamaji-lab

# Edit docs/kamaji-overview.md or add scripts

git add .
git commit -m "Add Cilium CNI setup for tenant clusters"
git push
```

---

## Recommended GitHub repo settings

Once pushed, configure via **Settings** on the repo page:

| Setting | Recommendation |
|---|---|
| **About** description | `Multi-tenant K8s platform lab — K3s, Kamaji, Capsule on macOS M3` |
| **Topics** | `kubernetes`, `kamaji`, `capsule`, `k3s`, `lima`, `platform-engineering`, `multi-tenancy` |
| **Releases** | Tag each major milestone: `v1.0-kamaji-capsule`, `v1.1-cilium`, etc. |
| **README** | Already included — renders on the repo home page |

---

## Final directory structure after setup

```
kamaji-lab/
├── .gitignore
├── README.md
├── GITHUB_SETUP.md           ← this file
├── docs/
│   ├── kamaji-overview.md    ← main guide
│   └── images/
│       └── kamaji-console-dashboard.png
├── scripts/
│   ├── shell-helpers.zsh
│   ├── setup-lima-k3s.sh
│   ├── setup-metallb-lima.sh
│   ├── install-kamaji.sh
│   ├── get-tenant-kubeconfig.sh
│   ├── setup-worker-node.sh
│   ├── setup-capsule.sh
│   ├── setup-kamaji-console.sh
│   ├── setup-kind.sh
│   ├── setup-rancher.sh
│   ├── teardown.sh
│   └── README.md
└── manifests/
    └── tenants/
        └── tenant-demo.yaml
```
