Import("env")

import os
import re
import subprocess


def resolve_build_id() -> str:
    configured = os.environ.get("RESQMESH_BUILD_ID", "").strip()
    if configured:
        candidate = configured[:12]
    else:
        candidate = subprocess.check_output(
            ["git", "rev-parse", "--short=12", "HEAD"],
            cwd=env.subst("$PROJECT_DIR"),
            text=True,
        ).strip()
    if re.fullmatch(r"[0-9a-fA-F]{12}", candidate) is None:
        raise RuntimeError(
            "RESQMESH firmware build identity must be a 12-character Git SHA"
        )
    return candidate


build_id = resolve_build_id()
env.Append(
    CPPDEFINES=[
        ("RESQMESH_FIRMWARE_BUILD_ID", f'\\"{build_id}\\"'),
    ]
)
print(f"ResQMesh firmware build ID: {build_id}")
