# TravelMemory — MERN Deployment on AWS using Terraform + Ansible

Deployment of the **TravelMemory** MERN application onto AWS, with the
infrastructure built by **Terraform** and every server configured by **Ansible**.

Nothing was clicked in the AWS Console and nothing was configured by hand on the
servers. The whole environment can be destroyed and rebuilt from these files with
two commands.

| | |
|---|---|
| **Application** | https://github.com/UnpredictablePrashant/TravelMemory |
| **Region** | `ap-south-1` (Mumbai) |
| **OS** | Ubuntu 22.04 LTS |
| **Instances** | 2 × `t3.micro` |
| **Database** | MongoDB 7.0, self-hosted on a private instance |

> **Why no MongoDB Atlas?** The task requires *"Install and configure MongoDB on
> the database server using Ansible."* A managed Atlas cluster would sit outside
> the VPC and make the private subnet and NAT Gateway pointless. MongoDB is
> therefore installed onto the private EC2 instance, which is the entire reason
> that subnet exists.

---

## 1. Architecture

```
                    Internet
                       │
                  [Internet Gateway]
                       │
   ┌───────────────────┴─────────────────── VPC 10.0.0.0/16 ──┐
   │                                                           │
   │  PUBLIC SUBNET 10.0.1.0/24      PRIVATE SUBNET 10.0.2.0/24│
   │  ┌──────────────────────┐       ┌───────────────────────┐ │
   │  │ WEB SERVER (EC2)     │       │ DB SERVER (EC2)       │ │
   │  │  • Node.js + Express │──────▶│  • MongoDB 7.0        │ │
   │  │  • React (built)     │ :27017│  • no public IP       │ │
   │  │  • Nginx :80         │       │                       │ │
   │  │  • Public IP ✔       │       └───────────────────────┘ │
   │  └──────────────────────┘                 ▲               │
   │            ▲                              │               │
   │            │                        [NAT Gateway]         │
   │       SSH from YOUR IP only     (lets DB download updates)│
   └───────────────────────────────────────────────────────────┘
```

### How the wiring actually works

**A page load:**

```
Browser ──► http://<public-ip>/          ──► Nginx serves the React build (static files)
Browser ──► http://<public-ip>/api/trip/ ──► Nginx strips "/api" ──► Express 127.0.0.1:3001/trip/
                                                                            │
                                                                            ▼
                                                        MongoDB 10.0.2.x:27017 (private)
```

Four points that make this design work, each of which is easy to get wrong:

1. **Only port 80 is open to the world.** Express (`3001`) listens on `127.0.0.1`
   and is not in any security group rule. Nginx is the single public entrance and
   reverse-proxies to it. One open port instead of three.

2. **The trailing slash in `proxy_pass` matters.** `proxy_pass http://127.0.0.1:3001/;`
   *strips* the `/api` prefix, so a browser request for `/api/trip/` arrives at
   Express as `/trip/` — which is the route the app actually defines. Without the
   trailing slash it would arrive as `/api/trip/` and 404.

3. **`REACT_APP_BACKEND_URL` points at the *public* IP, not the private one.**
   React code runs in the *visitor's browser*, which sits outside the VPC and has
   no idea what `10.0.2.x` means. Pointing it at the private IP is the single most
   common way this deployment gets broken.

4. **The database is genuinely unreachable from the internet.** No public IP, no
   route inbound, and its security group only accepts `27017` from the web
   server's security group. Its outbound access (for `apt` and the MongoDB repo)
   goes through the NAT Gateway, which is one-way.

### Why a bastion / jump host is needed

The DB server has no public IP, so Ansible cannot reach it directly. The
inventory tells SSH to connect to the **web server first** and tunnel onward:

```
Laptop ──SSH──► Web server (public) ──SSH tunnel──► DB server (private)
```

This is configured by `ProxyCommand` in `inventory.ini`, which Terraform
generates automatically.

---

## 2. Prerequisites

```bash
terraform version     # Terraform v1.7.5
aws --version         # aws-cli/2.35.11
ansible --version     # ansible [core 2.21.1]
```

**AWS credentials.** An IAM user with programmatic access was created in the
console (IAM → Users → Create user → attach `AdministratorAccess` → Security
credentials → Create access key → CLI), then:

```bash
aws configure
# AWS Access Key ID     : AKIA...
# AWS Secret Access Key : ...
# Default region name   : ap-south-1
# Default output format : json
```

Verify:

```bash
aws sts get-caller-identity
```

<details>
<summary>Expected output</summary>

```json
{
    "UserId": "AIDA...",
    "Account": "014166095913",
    "Arn": "arn:aws:iam::014166095913:user/bharathrm"
}
```
</details>

**SSH key pair.** Terraform uploads the public half to AWS; Ansible uses the
private half.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/travelmemory -N "" -C "travelmemory-assignment"
chmod 600 ~/.ssh/travelmemory
```

---

## 3. Repository layout

```
TravelMemory/
├── terraform/                    # Part 1 - infrastructure
│   ├── versions.tf               # provider versions + default tags
│   ├── variables.tf              # every tunable value
│   ├── vpc.tf                    # VPC, subnets, IGW, NAT GW, route tables
│   ├── security.tf               # security groups + auto-detection of admin IP
│   ├── iam.tf                    # EC2 IAM role + instance profile
│   ├── ec2.tf                    # the two instances + AMI lookup + key pair
│   ├── outputs.tf                # public IP output + generates the inventory
│   └── templates/inventory.tmpl  # template for ansible/inventory.ini
│
├── ansible/                      # Part 2 - configuration
│   ├── ansible.cfg               # how Ansible behaves
│   ├── inventory.ini             # GENERATED by Terraform - never edit by hand
│   ├── group_vars/all.yml        # shared variables (app, Node, MongoDB)
│   ├── db.yml                    # MongoDB install + users + lockdown
│   ├── web.yml                   # Node.js + app + systemd + Nginx
│   ├── harden.yml                # SSH, UFW, fail2ban, auto-updates
│   └── templates/                # Jinja2 templates rendered onto the servers
│
├── backend/   frontend/          # the MERN application itself
└── Images/                       # screenshots taken during the deployment
```

---

## 4. Part 1 — Infrastructure with Terraform

### 4.1 What each file does and why it is needed

| File | Purpose | Requirement |
|---|---|---|
| `versions.tf` | Pins the AWS provider to `~> 5.0` so the build is reproducible. Sets `default_tags` so every resource is tagged `Project=travelmemory` and is easy to find or clean up. | 1.1 |
| `variables.tf` | Every value that might change (region, CIDRs, instance type, key paths) in one place, so no IP or size is hard-coded across the config. | — |
| `vpc.tf` | The network: VPC, one public and one private subnet, Internet Gateway, NAT Gateway + its Elastic IP, and a route table for each subnet with its associations. | **1.2** |
| `security.tf` | Web SG (`80` from anywhere, `22` from the admin IP only) and DB SG (`27017` and `22` from the **web SG only** — never from `0.0.0.0/0`). Also auto-detects the admin's public IP. | **1.4** |
| `iam.tf` | An IAM role + instance profile so the instances can call AWS APIs with short-lived rotating credentials instead of access keys stored on disk. Attaches SSM (console shell access, vital for the *private* box) and CloudWatch. | **1.4** |
| `ec2.tf` | Looks up the latest official Canonical Ubuntu 22.04 AMI, uploads the SSH key, and launches the two instances — web with a public IP, DB deliberately without one. Encrypted gp3 root volumes and IMDSv2 required. | **1.3** |
| `outputs.tf` | Prints the web server's public IP (the required deliverable) and **generates `ansible/inventory.ini`** so IP addresses are never copied by hand. | **1.5** |
| `templates/inventory.tmpl` | The shape of the generated inventory, including the `ProxyCommand` that lets Ansible reach the private DB server. | 2.1 |

Two details worth calling out:

- **The admin IP is detected automatically.** `security.tf` queries
  `checkip.amazonaws.com` at plan time, so the SSH rule follows you if your home
  IP changes — no manual editing, and no accidental `0.0.0.0/0` on port 22.
- **A NAT Gateway must live in a *public* subnet and needs its own Elastic IP.**
  Private instances route `0.0.0.0/0` to it, which gives them outbound internet
  (to install MongoDB) while remaining unreachable from outside.

### 4.2 Commands

```bash
cd /home/bharath/Documents/BharathRM/Projects/TravelMemory/terraform

terraform init      # download providers
terraform fmt       # canonical formatting
terraform validate  # syntax + type checking (needs no AWS credentials)
terraform plan      # dry run - changes nothing
terraform apply     # type "yes" when prompted
```

**Expected:** `terraform validate` → `Success! The configuration is valid.`
`terraform plan` → `Plan: 26 to add, 0 to change, 0 to destroy.`
`terraform apply` takes 3–5 minutes; most of it is the NAT Gateway.

![Terraform plan showing 26 resources to add](Images/image.png)

![Terraform apply complete with the output values](Images/image2.png)

*Apply complete. The `web_server_public_ip` output is deliverable 1.5.*

### 4.3 Verifying the infrastructure

```bash
terraform output                       # re-print all outputs at any time
terraform output web_server_public_ip  # just the public IP
cat ../ansible/inventory.ini           # confirm the generated inventory
```

<details>
<summary>Expected output</summary>

```
admin_cidr_allowed_for_ssh = "152.57.16.201/32"
application_url            = "http://13.235.244.210"
db_server_private_ip       = "10.0.2.226"
nat_gateway_public_ip      = "13.205.141.224"
ssh_to_db                  = "ssh -i ~/.ssh/travelmemory -J ubuntu@13.235.244.210 ubuntu@10.0.2.226"
ssh_to_web                 = "ssh -i ~/.ssh/travelmemory ubuntu@13.235.244.210"
vpc_id                     = "vpc-0766ed1374cdb7141"
web_server_public_ip       = "13.235.244.210"
```
</details>

---

## 5. Part 2 — Configuring Ansible

```bash
cd /home/bharath/Documents/BharathRM/Projects/TravelMemory/ansible
mkdir -p group_vars templates
```

### 5.1 `ansible.cfg` — how Ansible behaves

**Why it is needed:** without it, Ansible would prompt for host-key confirmation
on every brand-new server, would not use `sudo`, and would re-open a fresh SSH
connection for every single task — painfully slow for the DB host, where each
connection has to be tunnelled through the bastion.

```bash
cat > ansible.cfg <<'EOF'
[defaults]
inventory            = ./inventory.ini
host_key_checking    = False
retry_files_enabled  = False
interpreter_python   = auto_silent
deprecation_warnings = False
timeout              = 60

# Readable YAML output. In ansible-core 2.13+ this is a setting on the
# built-in 'default' callback, NOT a separate 'yaml' callback plugin.
stdout_callback      = default
result_format        = yaml

[ssh_connection]
# Reuse one SSH connection across tasks - a big speed-up, and it matters
# doubly for the DB host where every connection jumps via the bastion.
pipelining = True
ssh_args   = -o ControlMaster=auto -o ControlPersist=120s -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null

[privilege_escalation]
become        = True
become_method = sudo
become_user   = root
EOF
```

> ⚠️ The first version of this file used `stdout_callback = yaml`, which broke.
> See **Problem 2** in section 10.

### 5.2 `group_vars/all.yml` — settings shared by every playbook

**Why it is needed:** package versions, paths, ports and database credentials
belong in one place, not scattered through three playbooks. IP addresses are
deliberately *not* here — Terraform injects those into `inventory.ini`, so the
playbooks stay correct after a rebuild.

```bash
cat > group_vars/all.yml <<'EOF'
---
# Variables shared by every playbook.
# IP addresses are NOT here - Terraform injects those into inventory.ini.

# --- Application ---
app_name: travelmemory
app_repo: "https://github.com/UnpredictablePrashant/TravelMemory.git"
app_dir: /opt/travelmemory
app_user: travelmemory          # unprivileged system user that runs Node
backend_port: 3001

# --- Node.js ---
nodejs_major_version: "20"

# --- MongoDB ---
mongodb_version: "7.0"
mongo_db_name: travelmemory

# Administrative (root-equivalent) MongoDB account
mongo_admin_user: mongoadmin
mongo_admin_password: "My_admin_545"

# Least-privilege account the app actually uses: readWrite on the
# travelmemory database ONLY. It cannot touch other DBs or create users.
mongo_app_user: travelapp
mongo_app_password: "My_app_545"
EOF
```

> **Production note:** these passwords are in plain text because this is a class
> exercise. In a real deployment they would be encrypted with `ansible-vault
> encrypt group_vars/all.yml` and unlocked at runtime with `--ask-vault-pass`.

### 5.3 Proving Ansible can reach both servers

```bash
ansible all -m ping
```

The `db-server` returning `pong` proves something worth understanding: your
laptop **cannot** reach `10.0.2.x` directly — it is a private address with no
route from the internet. Ansible got there by SSH-ing into the web server first
and tunnelling through it. That is requirement **2.1** solved properly.

![Ansible ping returning pong from both servers](Images/image3.png)

![Ansible ping succeeding against web-server and db-server](Images/image4.png)

<details>
<summary>Expected output</summary>

```yaml
web-server | SUCCESS => { "changed": false, "ping": "pong" }
db-server  | SUCCESS => { "changed": false, "ping": "pong" }
```
</details>

If a freshly-booted instance returns `Connection refused`, wait 60 seconds and
retry — `sshd` takes a moment to start.

---

## 6. Database server — MongoDB *(requirement 2.3)*

### 6.1 `templates/mongod.conf.j2`

**Why it is needed:** MongoDB ships wide open by default. This template does the
two things that make it safe — bind only to private addresses, and require
authentication. It is a **template**, not a static file, because
`ansible_default_ipv4.address` is filled in per host at runtime, so it stays
correct after any rebuild.

```bash
cd /home/bharath/Documents/BharathRM/Projects/TravelMemory/ansible

cat > templates/mongod.conf.j2 <<'EOF'
# Managed by Ansible - manual edits will be overwritten.

storage:
  dbPath: /var/lib/mongodb

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

net:
  port: 27017
  # SECURITY: listen on loopback + this host's private VPC address ONLY.
  # The public internet has no route here, and the security group further
  # restricts port 27017 to the web server's security group.
  bindIp: 127.0.0.1,{{ ansible_default_ipv4.address }}

processManagement:
  timeZoneInfo: /usr/share/zoneinfo

security:
  # SECURITY: without this, ANY client that reaches the port has full admin
  # rights. This is the single most important MongoDB setting.
  authorization: enabled
EOF
```

### 6.2 `db.yml`

**Why it is needed:** this is the whole database build — repository, packages,
users, lockdown and verification — in a form that can be replayed identically on
a new machine.

**The critical ordering decision:** users are created **first**, while
authentication is still off, and only **then** is `authorization: enabled`
applied and the service restarted. You cannot create the very first user on a
server that already demands a login — a classic chicken-and-egg. Idempotency is
preserved with a marker file (`/etc/mongodb-users-created`) so re-runs skip user
creation rather than failing.

```bash
cat > db.yml <<'EOF'
---
- name: Configure the private MongoDB database server
  hosts: db
  become: true

  tasks:
    - name: Wait for cloud-init to finish (prevents apt lock clashes)
      ansible.builtin.command: cloud-init status --wait
      changed_when: false
      failed_when: false

    - name: Install repository prerequisites
      ansible.builtin.apt:
        name: [curl, gnupg, ca-certificates]
        state: present
        update_cache: true
        cache_valid_time: 3600

    - name: Add the MongoDB {{ mongodb_version }} signing key
      ansible.builtin.shell:
        cmd: >
          curl -fsSL https://pgp.mongodb.com/server-{{ mongodb_version }}.asc
          | gpg --dearmor -o /usr/share/keyrings/mongodb-server-{{ mongodb_version }}.gpg
        creates: /usr/share/keyrings/mongodb-server-{{ mongodb_version }}.gpg

    - name: Add the MongoDB apt repository
      ansible.builtin.apt_repository:
        repo: >-
          deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-{{ mongodb_version }}.gpg ]
          https://repo.mongodb.org/apt/ubuntu
          {{ ansible_distribution_release }}/mongodb-org/{{ mongodb_version }} multiverse
        filename: mongodb-org-{{ mongodb_version }}
        state: present
        update_cache: true

    - name: Install MongoDB server and shell
      ansible.builtin.apt:
        name: mongodb-org
        state: present

    - name: Ensure MongoDB is running and enabled at boot
      ansible.builtin.service:
        name: mongod
        state: started
        enabled: true

    - name: Wait for MongoDB to accept connections
      ansible.builtin.wait_for:
        host: 127.0.0.1
        port: 27017
        delay: 2
        timeout: 90

    # --- Users: created BEFORE auth is switched on -------------------------
    - name: Check whether database users were already created
      ansible.builtin.stat:
        path: /etc/mongodb-users-created
      register: mongo_users_marker

    - name: Create MongoDB users
      when: not mongo_users_marker.stat.exists
      block:
        - name: Create the administrative (root) user
          ansible.builtin.command:
            argv:
              - mongosh
              - --quiet
              - --host
              - 127.0.0.1
              - --eval
              - >
                db.getSiblingDB("admin").createUser({
                  user: "{{ mongo_admin_user }}",
                  pwd: "{{ mongo_admin_password }}",
                  roles: [{ role: "root", db: "admin" }]
                })
          no_log: true

        - name: Create the least-privilege application user
          ansible.builtin.command:
            argv:
              - mongosh
              - --quiet
              - --host
              - 127.0.0.1
              - --eval
              - >
                db.getSiblingDB("{{ mongo_db_name }}").createUser({
                  user: "{{ mongo_app_user }}",
                  pwd: "{{ mongo_app_password }}",
                  roles: [{ role: "readWrite", db: "{{ mongo_db_name }}" }]
                })
          no_log: true

        - name: Record that users have been created
          ansible.builtin.file:
            path: /etc/mongodb-users-created
            state: touch
            mode: "0600"

    # --- Now lock the server down ------------------------------------------
    - name: Deploy hardened mongod.conf (private bind + auth required)
      ansible.builtin.template:
        src: templates/mongod.conf.j2
        dest: /etc/mongod.conf
        owner: root
        group: root
        mode: "0644"
        backup: true
      notify: Restart MongoDB

    - name: Apply the new configuration immediately
      ansible.builtin.meta: flush_handlers

    - name: Wait for MongoDB to come back after the restart
      ansible.builtin.wait_for:
        host: 127.0.0.1
        port: 27017
        delay: 3
        timeout: 90

    - name: Verify the application user can authenticate
      ansible.builtin.shell:
        cmd: >
          mongosh --quiet
          "mongodb://${MONGO_USER}:${MONGO_PASS}@127.0.0.1:27017/{{ mongo_db_name }}?authSource={{ mongo_db_name }}"
          --eval 'db.runCommand({ ping: 1 }).ok'
      environment:
        MONGO_USER: "{{ mongo_app_user }}"
        MONGO_PASS: "{{ mongo_app_password }}"
      register: mongo_auth_check
      changed_when: false

    - name: Report the verification result
      ansible.builtin.debug:
        msg: "Authenticated ping to '{{ mongo_db_name }}' returned: {{ mongo_auth_check.stdout | trim }}  (1 = success)"

  handlers:
    - name: Restart MongoDB
      ansible.builtin.service:
        name: mongod
        state: restarted
EOF
```

**Two users, on purpose:**

| User | Role | Used by |
|---|---|---|
| `mongoadmin` | `root` on `admin` | Human administration only |
| `travelapp` | `readWrite` on `travelmemory` **only** | The Node.js application |

If the application is ever compromised, the attacker holds `travelapp`
credentials — which cannot drop other databases, create users, or read anything
outside `travelmemory`. That is what *"create necessary users"* is really asking
for.

### 6.3 Verification

Ad-hoc check that the application user can authenticate:

```bash
ansible db -m command -a 'mongosh --quiet --host 127.0.0.1 -u travelapp -p My_app_545 --authenticationDatabase travelmemory travelmemory --eval "db.runCommand({ping:1}).ok"'
```

**Expected:** `db-server | CHANGED | rc=0 >>` followed by `1`.

![Ad-hoc mongosh authentication check returning 1](Images/image5.png)

Run the playbook:

```bash
ansible-playbook db.yml
```

![db.yml completing with failed=0 and the authenticated ping returning 1](Images/image6.png)

<details>
<summary>Expected output</summary>

```yaml
TASK [Report the verification result] ******
ok: [db-server] =>
  msg: "Authenticated ping to 'travelmemory' returned: 1  (1 = success)"

PLAY RECAP *********
db-server : ok=13  changed=0  unreachable=0  failed=0
```
</details>

A second run reporting `changed=0` is the proof of **idempotency** — the
playbook describes a desired state rather than a list of actions, so re-running
it changes nothing.

---

## 7. Web server — Node.js, React and Nginx *(requirements 2.2 and 2.4)*

### 7.1 The four templates

| Template | Rendered to | Why it is needed |
|---|---|---|
| `backend.env.j2` | `/opt/travelmemory/backend/.env` | Supplies `PORT` and `MONGO_URI`. The URI is built from `group_vars` + the DB's private IP from the inventory, so it is always correct after a rebuild. |
| `frontend.env.j2` | `/opt/travelmemory/frontend/.env` | Sets `REACT_APP_BACKEND_URL`. **Baked into the JS bundle at build time** — so it must be a URL the visitor's browser can reach. |
| `travelmemory-backend.service.j2` | `/etc/systemd/system/…` | Makes Express a managed service: starts on boot, restarts on crash, runs as an unprivileged user, with systemd sandboxing. |
| `nginx-travelmemory.conf.j2` | `/etc/nginx/sites-available/…` | Serves the React build and reverse-proxies `/api/` to Express, so only port 80 is public. |

```bash
cd /home/bharath/Documents/BharathRM/Projects/TravelMemory/ansible

cat > templates/backend.env.j2 <<'EOF'
# Managed by Ansible - do not edit by hand.
PORT={{ backend_port }}

# The app connects with the least-privilege 'travelapp' account, over the
# VPC's private network, to a host that has no route to the internet.
MONGO_URI='mongodb://{{ mongo_app_user }}:{{ mongo_app_password }}@{{ db_private_ip }}:27017/{{ mongo_db_name }}?authSource={{ mongo_db_name }}'
EOF

cat > templates/frontend.env.j2 <<'EOF'
# Managed by Ansible - do not edit by hand.
#
# Create React App bakes this value into the JavaScript bundle at BUILD time.
# It must be a URL the USER'S BROWSER can reach - NOT the private VPC address -
# because this code executes on the visitor's laptop, not on the server.
REACT_APP_BACKEND_URL=http://{{ web_public_ip }}/api
EOF

cat > templates/travelmemory-backend.service.j2 <<'EOF'
# Managed by Ansible - do not edit by hand.
[Unit]
Description=TravelMemory Express backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={{ app_user }}
Group={{ app_user }}
WorkingDirectory={{ app_dir }}/backend
ExecStart=/usr/bin/node index.js
Restart=on-failure
RestartSec=5
Environment=NODE_ENV=production

# --- Hardening: limit the blast radius if the app is ever compromised ---
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

cat > templates/nginx-travelmemory.conf.j2 <<'EOF'
# Managed by Ansible - do not edit by hand.
server {
    listen 80 default_server;
    server_name _;

    server_tokens off;   # don't advertise the nginx version

    root {{ app_dir }}/frontend/build;
    index index.html;

    # React Router owns client-side paths, so any unknown URL must still
    # return index.html rather than a 404.
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Reverse proxy to Express. The TRAILING SLASH on proxy_pass strips the
    # /api prefix: browser asks for /api/trip/  ->  Express receives /trip/
    location /api/ {
        proxy_pass http://127.0.0.1:{{ backend_port }}/;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF
```

### 7.2 `web.yml`

**Why it is needed:** it turns a bare Ubuntu box into a running application
server — swap, Node.js, the repository, dependencies, the production React
build, a managed service and a web server — and then proves the result works.

```bash
cat > web.yml <<'EOF'
---
- name: Deploy the TravelMemory MERN application on the public web server
  hosts: web
  become: true

  tasks:
    - name: Wait for cloud-init to finish (prevents apt lock clashes)
      ansible.builtin.command: cloud-init status --wait
      changed_when: false
      failed_when: false

    # --- Swap: t3.micro has only 1 GB RAM and the React build needs more ---
    - name: Check whether swap is already active
      ansible.builtin.command: swapon --show=NAME --noheadings
      register: swap_active
      changed_when: false

    - name: Create a 2 GB swap file
      when: "'/swapfile' not in swap_active.stdout"
      block:
        - name: Allocate the swap file
          ansible.builtin.command: fallocate -l 2G /swapfile
          args:
            creates: /swapfile

        - name: Restrict swap file permissions
          ansible.builtin.file:
            path: /swapfile
            owner: root
            group: root
            mode: "0600"

        - name: Format the swap file
          ansible.builtin.command: mkswap /swapfile

        - name: Enable the swap file
          ansible.builtin.command: swapon /swapfile

    - name: Persist swap across reboots
      ansible.builtin.lineinfile:
        path: /etc/fstab
        line: "/swapfile none swap sw 0 0"
        state: present

    # --- Packages ---------------------------------------------------------
    - name: Install base packages
      ansible.builtin.apt:
        name: [git, curl, gnupg, ca-certificates, nginx]
        state: present
        update_cache: true
        cache_valid_time: 3600

    - name: Add the NodeSource signing key
      ansible.builtin.shell:
        cmd: >
          curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key
          | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg
        creates: /usr/share/keyrings/nodesource.gpg

    - name: Add the NodeSource apt repository
      ansible.builtin.apt_repository:
        repo: >-
          deb [signed-by=/usr/share/keyrings/nodesource.gpg]
          https://deb.nodesource.com/node_{{ nodejs_major_version }}.x nodistro main
        filename: nodesource
        state: present
        update_cache: true

    - name: Install Node.js {{ nodejs_major_version }}
      ansible.builtin.apt:
        name: nodejs
        state: present

    - name: Report the installed Node.js and npm versions
      ansible.builtin.shell: node --version && npm --version
      register: node_versions
      changed_when: false

    # --- Application ------------------------------------------------------
    - name: Create the unprivileged application user
      ansible.builtin.user:
        name: "{{ app_user }}"
        system: true
        shell: /usr/sbin/nologin
        home: "{{ app_dir }}"
        create_home: false

    - name: Clone the TravelMemory repository
      ansible.builtin.git:
        repo: "{{ app_repo }}"
        dest: "{{ app_dir }}"
        force: true

    - name: Install backend dependencies
      ansible.builtin.command:
        cmd: npm install --no-audit --no-fund
        chdir: "{{ app_dir }}/backend"
        creates: "{{ app_dir }}/backend/node_modules"

    - name: Deploy the backend environment file
      ansible.builtin.template:
        src: templates/backend.env.j2
        dest: "{{ app_dir }}/backend/.env"
        owner: "{{ app_user }}"
        group: "{{ app_user }}"
        mode: "0640"
      notify: Restart backend

    - name: Deploy the frontend environment file
      ansible.builtin.template:
        src: templates/frontend.env.j2
        dest: "{{ app_dir }}/frontend/.env"
        mode: "0644"
      register: frontend_env

    - name: Install frontend dependencies (slow - a few minutes)
      ansible.builtin.command:
        cmd: npm install --no-audit --no-fund
        chdir: "{{ app_dir }}/frontend"
        creates: "{{ app_dir }}/frontend/node_modules"

    - name: Check whether a production build already exists
      ansible.builtin.stat:
        path: "{{ app_dir }}/frontend/build/index.html"
      register: react_build

    - name: Build the React production bundle (slow - a few minutes)
      ansible.builtin.command:
        cmd: npm run build
        chdir: "{{ app_dir }}/frontend"
      environment:
        CI: "false"      # treat lint warnings as warnings, not errors
      when: frontend_env.changed or not react_build.stat.exists
      changed_when: true

    - name: Hand ownership of the application to the app user
      ansible.builtin.file:
        path: "{{ app_dir }}"
        owner: "{{ app_user }}"
        group: "{{ app_user }}"
        recurse: true

    # --- Backend service --------------------------------------------------
    - name: Install the backend systemd unit
      ansible.builtin.template:
        src: templates/travelmemory-backend.service.j2
        dest: /etc/systemd/system/travelmemory-backend.service
        mode: "0644"
      notify: Restart backend

    - name: Enable and start the backend service
      ansible.builtin.systemd:
        name: travelmemory-backend
        state: started
        enabled: true
        daemon_reload: true

    # --- Nginx ------------------------------------------------------------
    - name: Deploy the Nginx site configuration
      ansible.builtin.template:
        src: templates/nginx-travelmemory.conf.j2
        dest: /etc/nginx/sites-available/travelmemory
        mode: "0644"
      notify: Reload Nginx

    - name: Enable the TravelMemory site
      ansible.builtin.file:
        src: /etc/nginx/sites-available/travelmemory
        dest: /etc/nginx/sites-enabled/travelmemory
        state: link
      notify: Reload Nginx

    - name: Remove the default Nginx site
      ansible.builtin.file:
        path: /etc/nginx/sites-enabled/default
        state: absent
      notify: Reload Nginx

    - name: Validate the Nginx configuration
      ansible.builtin.command: nginx -t
      changed_when: false

    - name: Apply pending restarts now
      ansible.builtin.meta: flush_handlers

    - name: Ensure Nginx is running and enabled at boot
      ansible.builtin.systemd:
        name: nginx
        state: started
        enabled: true

    # --- End-to-end verification -----------------------------------------
    - name: Verify Express answers through the Nginx proxy
      ansible.builtin.uri:
        url: http://127.0.0.1/api/hello
        return_content: true
      register: api_check
      retries: 6
      delay: 5
      until: api_check.status is defined and api_check.status == 200

    - name: Verify the backend can actually query MongoDB
      ansible.builtin.uri:
        url: http://127.0.0.1/api/trip/
        return_content: true
      register: trip_check
      retries: 6
      delay: 5
      until: trip_check.status is defined and trip_check.status == 200

    - name: Verify the React frontend is being served
      ansible.builtin.uri:
        url: http://127.0.0.1/
        return_content: true
      register: ui_check

    - name: Deployment summary
      ansible.builtin.debug:
        msg:
          - "Node/npm .............. {{ node_versions.stdout_lines | join(' / ') }}"
          - "GET /api/hello ........ {{ api_check.status }} -> {{ api_check.content }}"
          - "GET /api/trip/ ........ {{ trip_check.status }} (proves MongoDB is reachable)"
          - "GET / ................. {{ ui_check.status }} (React bundle served by Nginx)"
          - "Open the app at ....... http://{{ web_public_ip }}"

  handlers:
    - name: Restart backend
      ansible.builtin.systemd:
        name: travelmemory-backend
        state: restarted
        daemon_reload: true

    - name: Reload Nginx
      ansible.builtin.service:
        name: nginx
        state: reloaded
EOF
```

```bash
ansible-playbook web.yml
```

⏱️ Budget **8–12 minutes**. `npm install` and `npm run build` are heavy on a 1 GB
instance. If it appears frozen on *"Install frontend dependencies"*, it is not —
that is the swap file doing its job.

![web.yml deployment summary showing all checks returning 200 and failed=0](Images/image7.png)

*All three end-to-end checks return `200`, `failed=0`.*

![TravelMemory homepage loading in the browser with no trips yet](Images/image8.png)

*The application loads — but the page is empty below the header, because the
database has no records yet. `GET /api/trip/` returned `200` with `[]`. Nothing
is broken.*

---

## 8. Seeding sample data

This exercises the **entire chain from outside the VPC** — browser network path
→ Nginx → Express → MongoDB — and confirms writes work, not just reads.

```bash
IP=13.235.244.210

curl -s -X POST http://$IP/api/trip/ -H "Content-Type: application/json" -d '{
  "tripName": "Incredible India",
  "startDateOfJourney": "19-03-2022",
  "endDateOfJourney": "27-03-2022",
  "nameOfHotels": "Hotel Namaste, Backpackers Club",
  "placesVisited": "Delhi, Kolkata, Chennai, Mumbai",
  "totalCost": 800000,
  "tripType": "leisure",
  "experience": "A wonderful journey across four metros, full of colour, food and warm people.",
  "image": "https://t3.ftcdn.net/jpg/03/04/85/26/360_F_304852693_nSOn9KvUgafgvZ6wM0CNaULYUa7xXBkA.jpg",
  "shortDescription": "India is a wonderful country with rich culture and good people.",
  "featured": true
}'; echo

curl -s -X POST http://$IP/api/trip/ -H "Content-Type: application/json" -d '{
  "tripName": "Coorg Coffee Trail",
  "startDateOfJourney": "02-11-2023",
  "endDateOfJourney": "06-11-2023",
  "nameOfHotels": "Estate Stay Coorg",
  "placesVisited": "Madikeri, Abbey Falls, Dubare",
  "totalCost": 35000,
  "tripType": "leisure",
  "experience": "Misty mornings walking through coffee plantations in the Western Ghats.",
  "image": "https://images.unsplash.com/photo-1524350876685-274059332603",
  "shortDescription": "A short, restful weekend among the coffee estates of Karnataka.",
  "featured": false
}'; echo
```

![TravelMemory homepage showing the featured Incredible India card and the Coorg Coffee Trail card](Images/image9.png)

*Requirement **2.4** demonstrated end to end: the React frontend fetches from the
Express backend, which reads from MongoDB on the private instance.*

---

## 9. Security hardening *(requirement 2.5)*

### 9.1 `harden.yml`

**Why it is needed:** security groups protect the *network*; this playbook
protects the *hosts*. Together they form defence in depth — an attacker who
somehow bypasses the security group still meets a host firewall, key-only SSH,
and fail2ban.

```bash
cd /home/bharath/Documents/BharathRM/Projects/TravelMemory/ansible

cat > harden.yml <<'EOF'
---
- name: Security hardening for all TravelMemory servers
  hosts: all
  become: true

  tasks:
    # --- SSH lockdown -----------------------------------------------------
    - name: Deploy hardened SSH configuration
      ansible.builtin.copy:
        dest: /etc/ssh/sshd_config.d/00-hardening.conf
        mode: "0644"
        validate: /usr/sbin/sshd -t -f %s
        content: |
          # Managed by Ansible.
          # Ubuntu includes this directory from the TOP of sshd_config, and
          # sshd honours the FIRST value it sees for any option - so the "00"
          # prefix guarantees these settings win over everything else.
          PermitRootLogin no
          PasswordAuthentication no
          PubkeyAuthentication yes
          PermitEmptyPasswords no
          KbdInteractiveAuthentication no
          X11Forwarding no
          MaxAuthTries 3
          ClientAliveInterval 300
          ClientAliveCountMax 2
      notify: Restart SSH

    # --- Packages ---------------------------------------------------------
    - name: Install firewall, brute-force protection and auto-updates
      ansible.builtin.apt:
        name: [ufw, fail2ban, unattended-upgrades]
        state: present
        update_cache: true
        cache_valid_time: 3600

    - name: Enable automatic security updates
      ansible.builtin.copy:
        dest: /etc/apt/apt.conf.d/20auto-upgrades
        mode: "0644"
        content: |
          APT::Periodic::Update-Package-Lists "1";
          APT::Periodic::Unattended-Upgrade "1";

    - name: Configure fail2ban to ban SSH brute-force attempts
      ansible.builtin.copy:
        dest: /etc/fail2ban/jail.local
        mode: "0644"
        content: |
          [DEFAULT]
          bantime  = 1h
          findtime = 10m
          maxretry = 5

          [sshd]
          enabled = true
      notify: Restart fail2ban

    # --- Host firewall (defence in depth behind the security groups) ------
    - name: Set default firewall policies (deny everything inbound)
      community.general.ufw:
        direction: "{{ item.direction }}"
        policy: "{{ item.policy }}"
      loop:
        - { direction: incoming, policy: deny }
        - { direction: outgoing, policy: allow }

    - name: WEB - allow SSH from the administrator IP only
      community.general.ufw:
        rule: allow
        port: "22"
        proto: tcp
        src: "{{ admin_cidr }}"
      when: inventory_hostname in groups['web']

    - name: WEB - allow HTTP from anywhere
      community.general.ufw:
        rule: allow
        port: "80"
        proto: tcp
      when: inventory_hostname in groups['web']

    - name: DB - allow SSH from the public subnet (bastion) only
      community.general.ufw:
        rule: allow
        port: "22"
        proto: tcp
        src: "{{ public_subnet_cidr }}"
      when: inventory_hostname in groups['db']

    - name: DB - allow MongoDB from the public subnet only
      community.general.ufw:
        rule: allow
        port: "27017"
        proto: tcp
        src: "{{ public_subnet_cidr }}"
      when: inventory_hostname in groups['db']

    - name: Enable the firewall
      community.general.ufw:
        state: enabled

    # --- Prove it worked --------------------------------------------------
    - name: Read the EFFECTIVE sshd settings (not just the file on disk)
      ansible.builtin.shell:
        cmd: sshd -T | grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication|maxauthtries) '
      register: sshd_effective
      changed_when: false

    - name: Read the firewall state
      ansible.builtin.command: ufw status verbose
      register: ufw_status
      changed_when: false

    - name: Hardening summary
      ansible.builtin.debug:
        msg: "{{ sshd_effective.stdout_lines + [''] + ufw_status.stdout_lines }}"

  handlers:
    - name: Restart SSH
      ansible.builtin.service:
        name: ssh
        state: restarted

    - name: Restart fail2ban
      ansible.builtin.service:
        name: fail2ban
        state: restarted
EOF
```

![Creating and running the harden.yml playbook](Images/image10.png)

### 9.2 What was hardened

| Measure | Effect |
|---|---|
| `PermitRootLogin no` | Root cannot log in over SSH at all |
| `PasswordAuthentication no` | Key-based authentication only — passwords cannot be brute-forced |
| `MaxAuthTries 3` | Cuts off credential-guessing attempts early |
| UFW default deny inbound | Everything is blocked unless explicitly permitted |
| UFW web rules | `22` from the admin IP only, `80` from anywhere |
| UFW db rules | `22` and `27017` from `10.0.1.0/24` (the public subnet) only |
| fail2ban | Bans an IP for 1 hour after 5 failed SSH attempts in 10 minutes |
| `unattended-upgrades` | Security patches install automatically |
| systemd sandboxing | `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem`, `ProtectHome` on the Node service |
| IMDSv2 required | Blocks the SSRF attack class against instance metadata (set in Terraform) |
| Encrypted EBS volumes | Data at rest is encrypted (set in Terraform) |

**Why the DB's SSH rule allows a whole subnet, not one IP:** Ansible reaches the
DB *through* the web server, so the connection arrives from `10.0.1.x`. Allowing
only the laptop's IP there would have broken every future playbook run.

**Why enabling a firewall over SSH did not lock us out:** rules are added
*before* `ufw enable`, and UFW permits `ESTABLISHED,RELATED` connections by
default.

### 9.3 Verification

```bash
# Root login must be REFUSED
ssh -o BatchMode=yes -i ~/.ssh/travelmemory root@13.235.244.210 'whoami'

# Password auth must be OFF
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no ubuntu@13.235.244.210 'whoami'

# Key login must still WORK
ssh -i ~/.ssh/travelmemory ubuntu@13.235.244.210 'whoami'
```

**Expected:** the first two → `Permission denied (publickey)` — that *is* the
pass condition. The third → `ubuntu`.

![SSH hardening verification: root denied, password auth denied, key login succeeds](Images/image11.png)

Finally, confirm the hardened configuration is actually **loaded by the running
daemon** rather than merely written to disk, and that fail2ban is up:

```bash
ansible all -m ansible.builtin.shell -a "systemctl show ssh -p ActiveEnterTimestamp --value; stat -c '%y' /etc/ssh/sshd_config.d/00-hardening.conf; systemctl is-active fail2ban"
```

**Expected:** the *sshd running since* timestamp must be **later** than the
hardening file's timestamp — if sshd started first, it never loaded the file.
`fail2ban` must report `active`.

![Verification that sshd restarted after the hardening file was written and fail2ban is active on both hosts](Images/image12.png)

*Confirmed on both servers: the hardening file was written at `20:07:30 UTC` and
`sshd` has been running since `20:26:12 UTC` — 19 minutes later — so the
configuration is genuinely in effect. `fail2ban` reports `active` on both.*

> This check exists because of **Problem 5** below. A config file on disk proves
> nothing until the daemon reloads it, and `sshd -T` parses the *files* rather
> than the live process — so it cannot tell the two situations apart. Comparing
> the two timestamps can.

---

## 10. Problems faced and how they were fixed

### Problem 1 — Ansible refused to start: locale not UTF-8

```
ERROR: Ansible requires the locale encoding to be UTF-8; Detected ISO8859-1.
```

**Cause:** the workstation's locale was `en_IN`, which is not a UTF-8 locale.
**Fix:** appended to `~/.bashrc` and reopened the shell:

```bash
export LC_ALL=C.UTF-8
export LANG=C.UTF-8
```

**Verify:** `ansible --version` prints the version instead of the error.

---

### Problem 2 — `community.general.yaml` callback has been removed

```
[ERROR]: The 'community.general.yaml' callback plugin has been removed.
```

**Cause:** `ansible.cfg` contained `stdout_callback = yaml`. That plugin was
removed in `community.general` 12.0.0; the functionality moved into ansible-core.
**Fix:** in `ansible.cfg`, replace it with:

```ini
stdout_callback = default
result_format   = yaml
```

**Verify:** `ansible-config dump | grep -i result_format` → `yaml`.

---

### Problem 3 — MongoDB verification task failed with a censored error

```
fatal: [db-server]: FAILED! => {"censored": "the output has been hidden due to
the fact that 'no_log: true' was specified for this result", "changed": false}
```

**The real obstacle was not the failure — it was that we could not see it.**
`no_log: true`, added to keep the password out of the logs, also suppressed the
error message.

**Diagnosis:** the same `mongosh` command was run ad-hoc *(image5 above)* and
returned `rc=0` and `1` — so the command syntax was valid. The failure was a
**readiness race**: `wait_for` on port 27017 returns as soon as the socket is
listening, but `mongod` accepts TCP connections slightly before it can service
authentication, so the immediate verify ran too early.

**Fix:** the task was rewritten to use a single MongoDB connection URI and to
pass credentials through `environment:` instead of `no_log`:

```yaml
- name: Verify the application user can authenticate
  ansible.builtin.shell:
    cmd: >
      mongosh --quiet
      "mongodb://${MONGO_USER}:${MONGO_PASS}@127.0.0.1:27017/{{ mongo_db_name }}?authSource={{ mongo_db_name }}"
      --eval 'db.runCommand({ ping: 1 }).ok'
  environment:
    MONGO_USER: "{{ mongo_app_user }}"
    MONGO_PASS: "{{ mongo_app_password }}"
  register: mongo_auth_check
  changed_when: false
```

The logged command shows the literal text `${MONGO_PASS}` — the shell expands it
only on the remote host. **Real error messages *and* secrecy, instead of trading
one for the other.** The URI form also matches exactly what the Node backend
uses, so the test now exercises the same code path as the application.

**Lesson:** never wrap a task in `no_log` without a plan for how you will debug
it when it fails.

---

### Problem 4 — `Enable the firewall` hung indefinitely on the DB server

The play stopped at the UFW enable task and never returned.

**Diagnosis (done out-of-band, without killing the run):**

```bash
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

ssh $SSHOPTS -i $HOME/.ssh/travelmemory ubuntu@13.235.244.210 'sudo ufw status verbose'

ssh $SSHOPTS -i $HOME/.ssh/travelmemory \
  -o ProxyCommand="ssh $SSHOPTS -i $HOME/.ssh/travelmemory -W %h:%p ubuntu@13.235.244.210" \
  ubuntu@10.0.2.226 'sudo ufw status verbose'
```

Both returned `Status: active` with the correct rules — so `ufw enable` had
**already succeeded**. Ansible was waiting on a reply that would never arrive.

**Cause:** enabling UFW rewrites the entire iptables table, which flushed the
connection-tracking entry for the SSH session Ansible was using. It survived on
the web server and not on the DB server because the DB connection is *nested*
(tunnelled through the bastion) and therefore had two conntrack entries to lose.

**Fix:** `Ctrl+C`, then re-run. Because the playbook is idempotent and UFW was
already enabled, the re-run completed in seconds.

---

### Problem 5 — Handlers never ran, so the SSH hardening was not live

**Cause:** Ansible runs handlers at the *end* of a play. The aborted play never
reached the end, so `Restart SSH` and `Restart fail2ban` never fired. Worse, on
the re-run the config files were already correct, so those tasks reported `ok`
and did **not** notify their handlers again — leaving the files on disk but
never loaded by the running daemons.

**Subtle trap:** the playbook's `sshd -T` check reads the config *files*, not the
live daemon's memory, so it would have shown `permitrootlogin no` and looked like
a pass.

**Fix:** restart the services explicitly:

```bash
ansible all -m ansible.builtin.service -a 'name=ssh state=restarted'
ansible all -m ansible.builtin.service -a 'name=fail2ban state=restarted'
```

**Verify** that sshd started *after* the config was written:

```bash
ansible all -m ansible.builtin.shell -a "systemctl show ssh -p ActiveEnterTimestamp --value; stat -c '%y' /etc/ssh/sshd_config.d/00-hardening.conf"
```

Result: confirmed on both hosts — see the verification screenshot in section 9.3
(`sshd` running since `20:26:12 UTC`, hardening file written `20:07:30 UTC`).

---

### Problem 6 — `Host key verification failed` when pasting several SSH commands

**Cause:** SSH asked `Are you sure you want to continue connecting (yes/no)?` and
the *next pasted line* was consumed as the answer. Ansible never hits this
because `ansible.cfg` sets `StrictHostKeyChecking=False`.

**Fix:** trust the host key once, then run commands one at a time:

```bash
ssh-keyscan -H 13.235.244.210 >> ~/.ssh/known_hosts 2>/dev/null
```

---

### Problem 7 — The homepage loaded but showed no content

**Cause:** not a bug. `GET /api/trip/` returned `200` with an empty array — the
database simply had no records.
**Fix:** seeded two trips with the `curl` commands in section 8.

---

### Design decision — a 2 GB swap file on the web server

`t3.micro` has 1 GB of RAM; a Create React App production build routinely needs
around 1.5 GB. Without swap the build is killed by the kernel's OOM killer and
reports only a bare `Killed`, with no explanation. The swap file is created in
`web.yml` before any `npm` work begins.

### Cost note — the NAT Gateway is not free-tier

It costs roughly **$1/day**. The environment was destroyed between working
sessions and rebuilt with `terraform apply`, which required **no code changes at
all** — only the IP addresses differ, and those are regenerated into
`inventory.ini` automatically. This is precisely the benefit of infrastructure as
code.

---

## 11. Verification cheat sheet

| Check | Command | Expected |
|---|---|---|
| AWS credentials | `aws sts get-caller-identity` | JSON with your account ID |
| Terraform syntax | `terraform validate` | `Success! The configuration is valid.` |
| Infrastructure | `terraform output web_server_public_ip` | the public IP |
| Ansible reachability | `ansible all -m ping` | `pong` from **both** hosts |
| MongoDB auth | `ansible-playbook db.yml` | `returned: 1`, `failed=0` |
| Idempotency | re-run any playbook | `changed=0` |
| Backend via proxy | `curl http://<IP>/api/hello` | `Hello World!` |
| Backend → MongoDB | `curl http://<IP>/api/trip/` | JSON array of trips |
| Frontend | `curl -o /dev/null -w '%{http_code}' http://<IP>/` | `200` |
| Root SSH blocked | `ssh root@<IP>` | `Permission denied (publickey)` |
| Password SSH blocked | `ssh -o PubkeyAuthentication=no ubuntu@<IP>` | `Permission denied (publickey)` |
| Key SSH works | `ssh -i ~/.ssh/travelmemory ubuntu@<IP> whoami` | `ubuntu` |
| Firewalls | `ansible all -m command -a 'ufw status verbose'` | `Status: active` + correct rules |
| DB is private | `nc -zv -w 5 <db-private-ip> 27017` from your laptop | times out — no route |

---

## 12. Requirement coverage

### Part 1 — Infrastructure Setup with Terraform

| # | Requirement | Where | Status |
|---|---|---|---|
| 1.1 | AWS CLI configured; Terraform project initialised | `aws configure`, `terraform init`, `versions.tf` | ✅ |
| 1.2 | VPC with a public and a private subnet; IGW and NAT Gateway; route tables for both | `vpc.tf` | ✅ |
| 1.3 | Two EC2 instances (public web, private db); SSH access, public instance restricted to your IP | `ec2.tf`, `security.tf` | ✅ |
| 1.4 | Security groups for web and database; IAM roles for EC2 | `security.tf`, `iam.tf` | ✅ |
| 1.5 | Output the public IP of the web server | `outputs.tf` | ✅ |

### Part 2 — Configuration and Deployment with Ansible

| # | Requirement | Where | Status |
|---|---|---|---|
| 2.1 | Ansible configured to communicate with the EC2 instances | `ansible.cfg`, generated `inventory.ini` with `ProxyCommand` | ✅ |
| 2.2 | Install Node.js and npm; clone the repo and install dependencies | `web.yml` | ✅ |
| 2.3 | Install and configure MongoDB; secure it; create users and databases | `db.yml`, `mongod.conf.j2` | ✅ |
| 2.4 | Configure environment variables, start Node.js, frontend talks to backend | `backend.env.j2`, `frontend.env.j2`, systemd unit, Nginx proxy | ✅ |
| 2.5 | Harden security — firewalls, security groups, SSH keys, disable root login | `harden.yml` + Terraform security groups | ✅ |

### Deliverables

| Deliverable | Location |
|---|---|
| Terraform scripts for AWS infrastructure | `terraform/` |
| Ansible playbooks for configuration and deployment | `ansible/` |
| Detailed implementation report | this `README.md` |

---

## 13. Tearing the environment down

The NAT Gateway bills continuously, so destroy the environment when you are done:

```bash
cd /home/bharath/Documents/BharathRM/Projects/TravelMemory/terraform
terraform destroy      # type "yes"
```

**Expected:** `Destroy complete! Resources: 26 destroyed.`

Confirm nothing is left behind:

```bash
aws ec2 describe-instances --region ap-south-1 \
  --filters "Name=tag:Project,Values=travelmemory" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text

aws ec2 describe-nat-gateways --region ap-south-1 \
  --filter "Name=state,Values=available" --query 'NatGateways[].NatGatewayId' --output text
```

Both should return nothing. To bring the environment back, see section 14.

---

## 14. Rebuilding for a live demo

The environment is fully reproducible from this repository. Rebuilding from
nothing takes roughly **20 minutes** and needs **no code changes at all**:

```bash
cd terraform && terraform apply          # ~4 min
cd ../ansible
ansible-playbook db.yml                  # ~3 min
ansible-playbook web.yml                 # ~10 min
ansible-playbook harden.yml              # ~2 min
```

Then re-seed the sample data using the `curl` commands in section 8 — MongoDB's
data lives on the instance's disk and is destroyed along with it.

Three things differ on every rebuild, and all three are handled automatically:

| What changes | How it is handled |
|---|---|
| New web public IP and DB private IP | `outputs.tf` regenerates `ansible/inventory.ini` on every apply — never edit it by hand |
| Your home/office public IP | `security.tf` re-detects it via `checkip.amazonaws.com`, so the SSH rule follows you |
| `REACT_APP_BACKEND_URL` in the React bundle | `web.yml` re-renders `frontend.env.j2` and rebuilds the bundle when the value changes |

The only manual edit is the `IP=` variable in the seeding commands in section 8.

Verify the rebuild the same way as the original deployment:

```bash
ansible all -m ping                                          # both hosts -> pong
curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://<new-ip>/   # HTTP 200
```

> **Note:** `ansible/inventory.ini` is a Terraform-generated file. It is removed
> by `terraform destroy` and recreated by `terraform apply`, so its absence in a
> torn-down repository is expected, not a missing file.

---

## Appendix — Running the application locally

For local development (not part of the AWS deployment):

`.env` for the backend:

```
MONGO_URI='ENTER_YOUR_URL'
PORT=3001
```

`.env` for the frontend:

```bash
REACT_APP_BACKEND_URL=http://localhost:3001
```

Data format for a trip record:

```json
{
    "tripName": "Incredible India",
    "startDateOfJourney": "19-03-2022",
    "endDateOfJourney": "27-03-2022",
    "nameOfHotels":"Hotel Namaste, Backpackers Club",
    "placesVisited":"Delhi, Kolkata, Chennai, Mumbai",
    "totalCost": 800000,
    "tripType": "leisure",
    "experience": "Lorem Ipsum, Lorem Ipsum, Lorem Ipsum",
    "image": "https://t3.ftcdn.net/jpg/03/04/85/26/360_F_304852693_nSOn9KvUgafgvZ6wM0CNaULYUa7xXBkA.jpg",
    "shortDescription":"India is a wonderful country with rich culture and good people.",
    "featured": true
}
```

**Run the backend:**

```bash
cd backend
npm install
node index.js
```

**Run the frontend:**

```bash
cd frontend
npm install
npm start
```
