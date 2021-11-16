# What's in this repo?

Code to build a lab environment running the Elastic stack (Elasticsearch, Kibana, Fleet, Agent and Portainer) using only Docker-compose and Bash.

# Why?

Because installing all the Elastic components in a self-hosted/self-managed environment is still not very straightforward. 

# What would that look like?

![Architecture](./docs/architecture.png?raw=true)

# What's missing?

- Windows Agent deployment script - PowerShell
- HAProxy with TLS termination for ES and Fleet
- Logstash (looks like this one is getting phased out gradually)
- Generated object encryption key for Kibana
- Secure Fleet server communication with agents (it's HTTP at the moment)
- Version 8 compatibility checks

# How to run it?

- Prerequisites
  1. Freshly installed Ubuntu 20.04 LTS
  1. Internet access
  
- Clone this repo
- `sudo ./setup.sh`

- If you need to nuke everything and start fresh: `sudo ./setup.sh reset`
