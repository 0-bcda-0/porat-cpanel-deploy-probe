# Porat cPanel deployment capability probe

This temporary public repository contains a harmless, manually triggered capability probe for cPanel UAPI and Git deployment. It contains no Porat Staff application code or configuration and never references an application, public, weather, or database path.

The only remote filesystem scope is `/home/echosline/cpanel-deploy-probe`. The workflow uses HTTPS UAPI exclusively; it contains no SSH or SCP transport.

## Required GitHub configuration

Create a GitHub Environment named `development` and restrict it to the repository's `main` branch. Configure these non-secret Environment variables:

- `CPANEL_API_BASE_URL=https://cp077.mydataknox.com:2083`
- `CPANEL_USER=echosline`

Create a dedicated, short-lived cPanel token and store it only as the Environment secret `CPANEL_API_TOKEN`. Never paste it into issues, logs, commits, or chat. Run **cPanel capability probe** manually from the Actions tab only after local tests and repository review pass.

The workflow uses normal TLS verification, exact origin/user/controller allowlists, bounded request and polling timeouts, and serial execution. A polling timeout stops the run and never retriggers blindly.

After the experiment, revoke the temporary cPanel token. Archive or delete this repository after its non-secret results and controller commit SHA have been recorded in the authoritative Porat Staff repository.

## Local verification

```bash
tests/test-cpanel-uapi-probe.sh
tests/test-repository-contract.sh
bash -n scripts/cpanel-uapi-probe.sh probe-worker.sh tests/*.sh
```
