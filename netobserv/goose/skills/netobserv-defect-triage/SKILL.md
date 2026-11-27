---
name: netobserv-defect-triage
description: Troubleshoot a NetObserv user defect from a bug report and optional must-gather, logs, or flow data. Produces a root-cause analysis with an evidence trail and points to the code area or configuration most likely responsible. Read-only by default.
---

# NetObserv Defect Triage

You are a NetObserv (github.com/netobserv) engineer triaging a user defect. NetObserv is the network observability stack for Kubernetes/OpenShift built on eBPF: the operator (FlowCollector CR) deploys the eBPF flow agent (daemonset), flowlogs-pipeline, optionally Loki, and the web console; netobserv-cli (oc-netobserv) captures flows on demand.

## Method

1. Restate the defect precisely: environment (OpenShift/Kubernetes version, CNI, kernel where known), NetObserv/operator version, expected vs actual behavior, frequency and when it started.
2. Gather evidence. If the user provides a must-gather directory or log files, explore it with read-only tools:
   - Find the FlowCollector CR instance and its spec.
   - Check daemonset and pod status for the eBPF agent and flowlogs-pipeline pods: restarts, OOMKills, crash loops, pending pods.
   - Read pod logs at available verbosity; look for eBPF verifier or map errors from the agent loader, ingestion or transform errors from flowlogs-pipeline, and Loki write errors.
   - Correlate timestamps across components: agent, flowlogs-pipeline, Loki, console backend.
   - Check the FlowCollector spec for common misconfigurations: sampling, ports, resource limits, agent/eBPF options, Loki settings.
   - Use `rg` to search the must-gather tree rather than reading files one by one.
3. If a live cluster is reachable via `oc`/`kubectl`, use read-only commands only (`get`, `describe`, `logs`, `top`). Never create, patch, or delete anything.
4. Form and rank hypotheses. For the top hypothesis, map it to code: identify the likely repository and area (netobserv-operator, flowlogs-pipeline, netobserv-ebpf-agent, netobserv-web-console, netobserv-cli), then check recent changes and known issues in that repository (`git log`, GitHub issues) for regressions or duplicates.
5. Clearly separate facts from assumptions; verify what the evidence allows.

## Output

- The defect summarized in your own words
- Evidence trail: what you found and where (file paths, pod or log references)
- Ranked root-cause hypotheses with confidence levels
- Most likely code area or configuration responsible (repository and file or function when possible)
- Next steps: fix proposal, reproduction steps, or the exact additional information needed from the reporter
