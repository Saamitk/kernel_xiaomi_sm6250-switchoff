# Root integration patch artifacts

`root-integration-core.patch` is retained as a **historical pre-V1.0.4 snapshot**.
It predates the official KernelSU-Next upstream sync and its current SuSFS v2.3.0
compatibility overlay; do not apply it to reproduce or build V1.0.4.

The authoritative state is the current checked-in source plus the exact upstream
pins in `../upstreams.json`. The standalone `susfs/` patch remains the upstream
SuSFS v2.3.0-for-4.14 patch that was applied to the kernel tree.
`tools/root-integration/apply_droidspaces_cgroup.py` applies/verifies the style-adjusted,
applicable DroidSpaces legacy cgroup compatibility patch. See
`../../../docs/root-integration.md`
for the current integration notes and build workflow.
