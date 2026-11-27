"""Install a Modelica library and the libraries it uses as OpenModelica's package manager does, for a CI runner
without omc: from OpenModelica's package index, each as `<libraries>/<Name> <version>/`.

    python3 scripts/install_library.py <Name> <version> [<libraries dir>]

The libraries directory defaults to ~/.openmodelica/libraries (OMFrontend's libraryDirectories finds it). The MSL
packages (Modelica, ModelicaServices, Complex) are not installed: the coverage setup installs MSL 4.1.0 and
OMFrontend bundles 3.2.3, which OMFrontend uses for a `uses` of the same major version. Another library a library
uses is installed in the version its `uses` names (the index's version, or one that `provides` it).

Author: John Tinnerholm
"""
import io
import json
import os
import shutil
import sys
import urllib.request
import zipfile

INDEX_URL = "https://libraries.openmodelica.org/index/v1/index.json"
MSL_PACKAGES = {"Modelica", "ModelicaServices", "Complex"}


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=600) as response:
        return response.read()


def resolve(index: dict, name: str, version: str) -> tuple[str, dict]:
    """The index entry of `name` for `version`: the version itself, else one that provides it."""
    versions: dict = index["libs"][name]["versions"]
    if version in versions:
        return version, versions[version]
    for v, entry in versions.items():
        if version in entry.get("provides", []):
            return v, entry
    raise SystemExit(f"{name} {version} is not in OpenModelica's package index ({', '.join(versions)})")


def install(index: dict, name: str, version: str, libraries: str, done: set[str]) -> None:
    if name in MSL_PACKAGES or name in done:
        return
    done.add(name)
    v, entry = resolve(index, name, version)
    target = os.path.join(libraries, f"{name} {v}")
    if os.path.isdir(target):
        print(f"{name} {v}: installed")
    else:
        archive = zipfile.ZipFile(io.BytesIO(fetch(entry["zipfile"])))
        top: str = archive.namelist()[0].split("/")[0]
        prefix: str = f"{top}/{entry['path']}"
        tmp = target + ".tmp"
        shutil.rmtree(tmp, ignore_errors=True)
        for member in archive.namelist():
            if member != prefix and not member.startswith(prefix + "/"):
                continue
            rel: str = member[len(prefix):].lstrip("/")
            # a single-file package (Name.mo) becomes Name <version>/package.mo
            out = os.path.join(tmp, "package.mo" if member == prefix else rel)
            if member.endswith("/"):
                os.makedirs(out, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with archive.open(member) as src, open(out, "wb") as dst:
                shutil.copyfileobj(src, dst)
        if not os.path.isfile(os.path.join(tmp, "package.mo")):
            raise SystemExit(f"{name} {v}: no package.mo under {prefix} in {entry['zipfile']}")
        os.rename(tmp, target)
        print(f"{name} {v}: installed from {entry['zipfile']}")
    for dep, depVersion in entry.get("uses", {}).items():
        install(index, dep, depVersion, libraries, done)


def main() -> None:
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)
    libraries: str = sys.argv[3] if len(sys.argv) == 4 else os.path.expanduser("~/.openmodelica/libraries")
    os.makedirs(libraries, exist_ok=True)
    index: dict = json.loads(fetch(INDEX_URL))
    install(index, sys.argv[1], sys.argv[2], libraries, set())


if __name__ == "__main__":
    main()
