---
name: project-dev10-polars-cpu-masked
description: atc-cache-dev10's VM hides AVX2/FMA/BMI1/BMI2/LZCNT/MOVBE, so wpy's polars warns "Missing required CPU features" but works; the user chose to keep polars' default runtime, not rtcompat.
metadata:
  type: project
---

atc-cache-dev10 is a VMware guest (Xeon Gold 6336Y, Ice Lake) whose CPUID lacks avx2, fma, bmi1,
bmi2, lzcnt and movbe (exactly Haswell's additions: likely an older EVC baseline; inferred, not
confirmed with the admins). Polars 2.0's `polars-runtime-32` warns on import, including in
tool-env's smoke check, yet a sum over 100k rows ran correctly on 2026-11-03: masking hides the
features but the physical CPU still executes them. It would crash (`Illegal instruction`) only if
the VM moved to an older physical host.

**Why:** on 2026-11-03 the user chose to leave `environments/python` as is. `polars[rtcompat]`
would be safe there, but polars' loader (`polars/_plr.py`) prefers the compat runtime whenever it
is installed, so every host would lose the fast build.
**How to apply:** the warning there is expected. If an `Illegal instruction` appears on that host,
offer `polars[rtcompat]` (or `POLARS_PREFER_PKG=32` on AVX2 hosts) again. `POLARS_SKIP_CPU_CHECK=1`
only silences the warning. Host context: [[project-directory-accounts-sssd]],
[[project-dev10-graft-hand-installed]].
