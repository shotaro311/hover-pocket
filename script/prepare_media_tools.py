"""Prepare pinned, replaceable FFmpeg helpers at build time, never at runtime."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def verified_archive(lock: dict, cache: Path) -> Path:
    archive = cache / lock.get("filename", Path(lock["url"]).name)
    if not archive.exists():
        temporary = archive.with_suffix(".download")
        with urllib.request.urlopen(lock["url"], timeout=120) as response, temporary.open("wb") as destination:
            shutil.copyfileobj(response, destination)
        temporary.replace(archive)
    digest = hashlib.sha256()
    with archive.open("rb") as data:
        for block in iter(lambda: data.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != lock["sha256"]:
        raise RuntimeError("Media helper archive failed SHA256 verification")
    return archive


def prepare(target: str, output: Path) -> None:
    lock = json.loads((ROOT / "shared/asset-library/media-tools.lock.json").read_text(encoding="utf-8"))[target]
    cache = ROOT / "artifacts" / ("media-tools-" + target + "-" + platform.machine())
    cache.mkdir(parents=True, exist_ok=True)
    archive = verified_archive(lock, cache)
    output.mkdir(parents=True, exist_ok=True)
    if target == "windows":
        source = cache / "source"
        if not source.exists():
            with zipfile.ZipFile(archive) as package:
                for member in package.infolist():
                    if not (source / member.filename).resolve().is_relative_to(source.resolve()):
                        raise RuntimeError("Archive path escapes build cache")
                package.extractall(source)
        executable = next(source.rglob("ffmpeg.exe"))
        for file in executable.parent.iterdir():
            if file.name == "ffmpeg.exe" or file.suffix.lower() == ".dll":
                shutil.copy2(file, output / file.name)
        for file in executable.parent.parent.iterdir():
            if file.is_file() and ("license" in file.name.lower() or "readme" in file.name.lower()):
                shutil.copy2(file, output / file.name)
        for entry in lock["sources"]:
            package = verified_archive(entry, cache)
            shutil.copy2(package, output / package.name)
            if package.name.endswith(".tar.gz"):
                with tarfile.open(package) as source_package:
                    for member in source_package.getmembers():
                        if Path(member.name).name in ["COPYING.LGPLv3", "COPYING.GPLv3"]:
                            data = source_package.extractfile(member)
                            if data is not None:
                                (output / Path(member.name).name).write_bytes(data.read())
    else:
        if platform.system() != "Darwin":
            raise RuntimeError("Build the macOS helper on macOS")
        source = cache / "ffmpeg-8.1.3"
        if not source.exists():
            with tarfile.open(archive) as package:
                package.extractall(cache, filter="data")
        executable = source / "ffmpeg"
        configure = ["./configure", "--disable-shared", "--enable-static", "--disable-autodetect",
                     "--disable-gpl", "--disable-nonfree", "--disable-doc", "--disable-debug",
                     "--disable-network", "--disable-avdevice", "--disable-ffplay", "--disable-ffprobe",
                     "--enable-videotoolbox", "--enable-audiotoolbox", "--enable-zlib"]
        marker = source / "hoverpocket-build-command.json"
        if not executable.exists() or not marker.exists() or json.loads(marker.read_text()) != configure:
            with (cache / "build.log").open("w") as log:
                subprocess.run(configure, cwd=source, stdout=log, stderr=subprocess.STDOUT, check=True)
                subprocess.run(["make", "-j", str(min(8, os.cpu_count() or 2))], cwd=source,
                               stdout=log, stderr=subprocess.STDOUT, check=True)
            marker.write_text(json.dumps(configure))
        shutil.copy2(executable, output / "ffmpeg")
        for name in ["COPYING.LGPLv2.1", "COPYING.LGPLv3", "LICENSE.md", "ffbuild/config.mak"]:
            shutil.copy2(source / name, output / Path(name).name)
        # Provide the exact corresponding source and build configuration with the helper.
        shutil.copy2(archive, output / archive.name)
        (output / "build-command.txt").write_text(" ".join(configure) + "\nmake -j8\n")
    (output / "NOTICE.txt").write_text(
        "FFmpeg is a separate, replaceable executable used for local media previews.\n"
        "Original library files are never overwritten.\n"
        "Source and build recipe: " + lock["source"] + "\n"
        "Archive SHA256: " + lock["sha256"] + "\n"
        "License: GNU LGPL; see the included license and configuration files.\n"
        "https://ffmpeg.org/legal.html\n", encoding="utf-8")
    print("Prepared media helper:", output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=["windows", "macos"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.platform, args.output.resolve())
