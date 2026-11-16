#!/usr/bin/env python3
"""mc — launch a Minecraft (Fabric/Quilt/Vanilla/Forge) instance straight from the terminal.

No launcher GUI involved: it reads the version JSON that HMCL / the official
launcher already downloaded, assembles the classpath, unpacks natives and
execs java. Works on Linux, macOS and Windows.

Usage:
    mc                        # launch the newest instance
    mc --list                 # list installed instances
    mc 1.21.4-fabric          # launch a specific instance
    mc --fullscreen           # start fullscreen
    mc --dry-run              # print the java command instead of running it

Environment:
    MC_DIR      path to the .minecraft directory (auto-detected otherwise)
    MC_USER     player name (default: $USER)
    MC_UUID     player UUID (default: offline UUID derived from the name)
    MC_TOKEN    access token (default: 0 -> offline mode)
    MC_MEM      heap size (default: 2G)
    MC_JAVA     explicit java binary, skips auto-detection
    MC_JVM_ARGS extra JVM args, space separated (quotes allowed)
    MC_WIDTH / MC_HEIGHT  initial window size (default 854x480)

Offline mode only: no Mojang / authlib-injector authentication is performed,
so singleplayer works but online servers will reject the session.
"""

import hashlib
import json
import os
import platform
import shlex
import shutil
import subprocess
import sys
import uuid as uuidlib
import zipfile

HOME = os.path.expanduser("~")
DEFAULT_MEM = os.environ.get("MC_MEM", "2G")
IS_WINDOWS = os.name == "nt"

PLATFORM = os.environ.get("MC_PLATFORM") or (
    "windows" if IS_WINDOWS else "osx" if sys.platform == "darwin" else "linux"
)
_MACHINE = (os.environ.get("MC_ARCH") or platform.machine() or "").lower()
ARCH = "aarch64" if _MACHINE in ("arm64", "aarch64") else "x86_64"
_NATIVE_EXT = ".dll" if PLATFORM == "windows" else ".dylib" if PLATFORM == "osx" else ".so"

HELP = __doc__.split("\n\n", 1)[1]


def die(msg):
    sys.exit("mc: " + msg)


def find_mc_dir():
    """Locate the .minecraft directory."""
    env = os.environ.get("MC_DIR")
    if env:
        return os.path.expanduser(env)
    candidates = []
    if PLATFORM == "windows":
        appdata = os.environ.get("APPDATA")
        if appdata:
            candidates.append(os.path.join(appdata, ".minecraft"))
        candidates.append(os.path.join(HOME, "AppData", "Roaming", ".minecraft"))
    elif PLATFORM == "osx":
        candidates.append(os.path.join(HOME, "Library", "Application Support", "minecraft"))
    candidates += [
        os.path.join(HOME, ".minecraft"),
        os.path.join(HOME, "桌面", ".minecraft"),
        os.path.join(HOME, "Desktop", ".minecraft"),
        os.path.join(HOME, ".local", "share", "minecraft"),
    ]
    for c in candidates:
        if os.path.isdir(os.path.join(c, "versions")):
            return c
    die("cannot find .minecraft, set MC_DIR")


def list_versions(mc_dir):
    vroot = os.path.join(mc_dir, "versions")
    if not os.path.isdir(vroot):
        return []
    out = []
    for name in os.listdir(vroot):
        j = os.path.join(vroot, name, name + ".json")
        if os.path.isfile(j):
            out.append((os.path.getmtime(j), name))
    return [n for _, n in sorted(out, reverse=True)]


def java_major(binary):
    """Return the major version of a java binary, or None."""
    try:
        proc = subprocess.run(
            [binary, "-version"], capture_output=True, text=True, timeout=15
        )
    except (OSError, subprocess.SubprocessError):
        return None
    for line in (proc.stderr or proc.stdout or "").splitlines():
        if 'version "' in line:
            ver = line.split('version "')[1].split('"')[0]
            try:
                return int(ver.split(".")[0]) if not ver.startswith("1.") else int(ver.split(".")[1])
            except (IndexError, ValueError):
                return None
    return None


def java_candidates():
    """Yield possible java binaries, platform aware."""
    env = os.environ.get("MC_JAVA")
    if env:
        yield env
    home = os.environ.get("JAVA_HOME")
    if home:
        yield os.path.join(home, "bin", "java.exe" if IS_WINDOWS else "java")

    roots = []
    if PLATFORM == "windows":
        for base in (
            os.environ.get("ProgramFiles", r"C:\Program Files"),
            os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
            os.environ.get("LOCALAPPDATA", ""),
        ):
            if not base:
                continue
            for vendor in ("Java", "Eclipse Adoptium", "Microsoft", "Zulu", "BellSoft", "Amazon Corretto"):
                roots.append(os.path.join(base, vendor))
        roots.append(os.path.join(HOME, ".jdks"))
    elif PLATFORM == "osx":
        roots += [
            "/Library/Java/JavaVirtualMachines",
            "/opt/homebrew/opt",
            "/usr/local/opt",
        ]
    else:
        roots += ["/usr/lib/jvm", "/opt/java", "/usr/java"]

    exe = "java.exe" if IS_WINDOWS else "java"
    for root in roots:
        if not os.path.isdir(root):
            continue
        for entry in sorted(os.listdir(root)):
            full = os.path.join(root, entry)
            for rel in (os.path.join("bin", exe), os.path.join("Contents", "Home", "bin", exe)):
                binary = os.path.join(full, rel)
                if os.path.isfile(binary):
                    yield binary

    found = shutil.which("java")
    if found:
        yield found


def pick_java(required):
    """Return a java binary whose major version is >= required."""
    best = None
    seen = set()
    for binary in java_candidates():
        key = os.path.realpath(binary) if os.path.exists(binary) else binary
        if key in seen:
            continue
        seen.add(key)
        major = java_major(binary)
        if major is None or major < required:
            continue
        # prefer the smallest (most conservative) version that is new enough
        if best is None or major < best[0]:
            best = (major, binary)
    if best:
        return best[1]
    die(f"no java >= {required} found, set MC_JAVA")


def rule_applies(rules):
    """Evaluate a version-JSON rule list for this OS/arch, no extra features."""
    allow = False
    for rule in rules:
        ok = True
        os_rule = rule.get("os", {})
        if "name" in os_rule and os_rule["name"] != PLATFORM:
            ok = False
        if "arch" in os_rule:
            wanted = os_rule["arch"]
            aliases = {
                "x86_64": ("x86_64", "amd64", "x64"),
                "aarch64": ("arm64", "aarch64"),
            }[ARCH]
            if wanted not in aliases:
                ok = False
        if "version" in os_rule:
            ok = False  # kernel version predicates are not supported
        for value in rule.get("features", {}).values():
            if value:
                ok = False  # demo/user/quickplay features are all off
        if ok:
            allow = rule.get("action") == "allow"
    return allow


def lib_path(mc_dir, coord):
    parts = coord.split(":")
    group, artifact, version = parts[0], parts[1], parts[2]
    classifier = parts[3] if len(parts) > 3 else None
    filename = f"{artifact}-{version}" + (f"-{classifier}" if classifier else "") + ".jar"
    return os.path.join(mc_dir, "libraries", group.replace(".", "/"), artifact, version, filename)


def merge_versions(parent, child):
    """Merge an inheriting version JSON on top of its parent (official rules)."""
    merged = dict(parent)
    for key, value in child.items():
        if key in ("libraries", "arguments"):
            continue
        merged[key] = value  # scalar fields: child wins

    libs, seen = [], set()
    for lib in list(child.get("libraries", [])) + list(parent.get("libraries", [])):
        name = lib.get("name")
        if name in seen:
            continue
        seen.add(name)
        libs.append(lib)
    merged["libraries"] = libs

    parent_args = parent.get("arguments") or {}
    child_args = child.get("arguments") or {}
    if parent_args or child_args:
        merged["arguments"] = {
            "game": list(parent_args.get("game", [])) + list(child_args.get("game", [])),
            "jvm": list(parent_args.get("jvm", [])) + list(child_args.get("jvm", [])),
        }
    elif "arguments" in merged:
        merged.pop("arguments")
    return merged


def load_version(mc_dir, version):
    """Load a version JSON, resolving inheritsFrom chains."""
    chain, data = [], None
    current = version
    while current:
        vdir = os.path.join(mc_dir, "versions", current)
        path = os.path.join(vdir, current + ".json")
        if not os.path.isfile(path):
            die(f"missing version json for '{current}'")
        with open(path, encoding="utf-8") as fh:
            raw = json.load(fh)
        chain.append(current)
        data = merge_versions(raw, data) if data else raw  # raw is the parent here
        current = raw.get("inheritsFrom")
    return data, chain


def find_client_jar(mc_dir, version, chain, vjson):
    """Which client jar to put on the classpath."""
    candidates = []
    if vjson.get("jar"):
        candidates.append(vjson["jar"])
    candidates.extend(chain)
    candidates.append(version)
    for vid in candidates:
        jar = os.path.join(mc_dir, "versions", vid, vid + ".jar")
        if os.path.isfile(jar):
            return jar
    return os.path.join(mc_dir, "versions", version, version + ".jar")


def offline_uuid(name):
    digest = bytearray(hashlib.md5(f"OfflinePlayer:{name}".encode()).digest())
    digest[6] = (digest[6] & 0x0F) | 0x30  # version 3
    digest[8] = (digest[8] & 0x3F) | 0x80  # variant
    return str(uuidlib.UUID(bytes=bytes(digest)))


def main(argv):
    if "-h" in argv or "--help" in argv:
        print(HELP)
        return

    mc_dir = find_mc_dir()
    versions = list_versions(mc_dir)
    if not versions:
        die(f"no installed versions in {mc_dir}/versions")

    if "--list" in argv:
        for v in versions:
            print(v)
        return

    version = next((a for a in argv if not a.startswith("-")), versions[0])
    fullscreen = "--fullscreen" in argv
    dry_run = "--dry-run" in argv

    vdir = os.path.join(mc_dir, "versions", version)
    if not os.path.isfile(os.path.join(vdir, version + ".json")):
        die(f"unknown instance '{version}' (try: mc --list)")
    vjson, chain = load_version(mc_dir, version)

    # ---- classpath -------------------------------------------------------
    classpath = []
    natives = os.path.join(vdir, f"natives-{PLATFORM}-{ARCH}")
    os.makedirs(natives, exist_ok=True)

    for lib in vjson.get("libraries", []):
        if "rules" in lib and not rule_applies(lib["rules"]):
            continue
        name = lib.get("name", "")
        parts = name.split(":")
        classifier = parts[3] if len(parts) > 3 else None
        has_natives = "natives" in lib or (classifier or "").startswith("natives")
        jar = lib_path(mc_dir, name)
        if not os.path.isfile(jar):
            continue
        if not has_natives:
            classpath.append(jar)
            continue
        try:
            with zipfile.ZipFile(jar) as zf:
                for member in zf.namelist():
                    if member.endswith(_NATIVE_EXT) and "/" not in member and "\\" not in member:
                        target = os.path.join(natives, member)
                        if not os.path.exists(target):
                            zf.extract(member, natives)
        except zipfile.BadZipFile:
            pass

    client_jar = find_client_jar(mc_dir, version, chain, vjson)
    if os.path.isfile(client_jar):
        classpath.append(client_jar)

    # ---- launch arguments ------------------------------------------------
    name = os.environ.get("MC_USER") or os.environ.get("USER") or os.environ.get("USERNAME") or "Player"
    player_uuid = os.environ.get("MC_UUID") or offline_uuid(name)
    token = os.environ.get("MC_TOKEN", "0")
    cp = os.pathsep.join(classpath)

    variables = {
        "auth_player_name": name,
        "version_name": version,
        "game_directory": vdir,
        "assets_root": os.path.join(mc_dir, "assets"),
        "game_assets": os.path.join(mc_dir, "assets", "virtual", "legacy"),
        "assets_index_name": vjson.get("assetIndex", {}).get("id", "0"),
        "auth_uuid": player_uuid,
        "auth_access_token": token,
        "auth_session": token,
        "clientid": "0",
        "auth_xuid": "0",
        "user_type": "msa",
        "version_type": "mc-cli",
        "natives_directory": natives,
        "launcher_name": "mc",
        "launcher_version": "1.0",
        "classpath": cp,
        "classpath_separator": os.pathsep,
        "library_directory": os.path.join(mc_dir, "libraries"),
        "resolution_width": os.environ.get("MC_WIDTH", "854"),
        "resolution_height": os.environ.get("MC_HEIGHT", "480"),
    }

    def resolve(value):
        if isinstance(value, list):
            return [resolve(v) for v in value]
        if isinstance(value, str):
            for key, val in variables.items():
                value = value.replace("${" + key + "}", str(val))
        return value

    def collect(items):
        out = []
        for item in items:
            if isinstance(item, str):
                out.append(resolve(item))
            elif isinstance(item, dict):
                if "rules" not in item or rule_applies(item["rules"]):
                    vals = item.get("value", [])
                    out.extend(collect([vals] if isinstance(vals, str) else vals))
        return out

    arguments = vjson.get("arguments") or {}
    if arguments:
        jvm_args = collect(arguments.get("jvm", []))
        game_args = collect(arguments.get("game", []))
    else:  # pre-1.13 format
        jvm_args = ["-Djava.library.path=${natives_directory}", "-cp", "${classpath}"]
        game_args = [resolve(a) for a in vjson.get("minecraftArguments", "").split()]

    # keep -cp from the JSON, replace the heap settings with ours
    jvm_args = [a for a in jvm_args if not a.startswith(("-Xmx", "-Xms"))]
    if "-cp" not in jvm_args and "-classpath" not in jvm_args:
        jvm_args += ["-cp", cp]

    if fullscreen:
        game_args.append("--fullscreen")

    required = int((vjson.get("javaVersion") or {}).get("majorVersion", 21))
    java = pick_java(required)

    try:
        extra = shlex.split(os.environ.get("MC_JVM_ARGS", ""), posix=not IS_WINDOWS)
    except ValueError as exc:
        die(f"cannot parse MC_JVM_ARGS: {exc}")

    cmd = (
        [java, f"-Xmx{DEFAULT_MEM}"]
        + extra
        + [
            "-Dfile.encoding=UTF-8",
            "-Dstdout.encoding=UTF-8",
            "-Dstderr.encoding=UTF-8",
            f"-Dminecraft.client.jar={client_jar}",
            "-Dminecraft.launcher.brand=mc",
            "-Dminecraft.launcher.version=1.0",
        ]
        + jvm_args
        + [vjson["mainClass"]]
        + game_args
    )

    if dry_run:
        print(subprocess.list2cmdline(cmd) if IS_WINDOWS else shlex.join(cmd))
        return

    os.chdir(mc_dir)
    print(f"[mc] {version} | java {required} | {DEFAULT_MEM} | user {name}", file=sys.stderr)
    try:
        if IS_WINDOWS:
            # os.execv on Windows cannot replace the console process cleanly
            sys.exit(subprocess.call(cmd))
        os.execv(java, cmd)
    except OSError as exc:
        die(f"exec failed: {exc}")


if __name__ == "__main__":
    main(sys.argv[1:])
