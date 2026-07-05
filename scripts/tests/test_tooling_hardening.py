import contextlib
import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]


class ToolingHardeningTests(unittest.TestCase):
    @contextlib.contextmanager
    def make_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "Tooling Test"], cwd=root, check=True)
            (root / "scripts").mkdir()
            (root / "Labstream").mkdir()
            yield root

    def copy_script(self, root: Path, name: str):
        dest = root / "scripts" / name
        shutil.copy2(REPO / "scripts" / name, dest)
        dest.chmod(dest.stat().st_mode | stat.S_IXUSR)
        return dest

    def commit_all(self, root: Path):
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "baseline"], cwd=root, check=True)

    def test_build_version_args_marks_untracked_app_source_dirty(self):
        with self.make_repo() as root:
            self.copy_script(root, "build-version-args.sh")
            (root / "Labstream" / "Existing.swift").write_text("// baseline\n")
            self.commit_all(root)

            clean = subprocess.check_output(["scripts/build-version-args.sh"], cwd=root, text=True)
            self.assertIn("LABSTREAM_BUILD_SLUG=", clean)
            self.assertIn("-clean", clean)

            (root / "Labstream" / "NewView.swift").write_text("// untracked but build-relevant\n")
            dirty = subprocess.check_output(["scripts/build-version-args.sh"], cwd=root, text=True)
            self.assertIn("-dirty", dirty)

    def test_xcodebuild_versioned_passes_dirty_slug_for_untracked_asset(self):
        with self.make_repo() as root:
            self.copy_script(root, "xcodebuild-versioned.sh")
            fakebin = root / "fakebin"
            fakebin.mkdir()
            args_file = root / "xcodebuild-args.txt"
            (fakebin / "xcodebuild").write_text(f"#!/usr/bin/env bash\nprintf '%s\\n' \"$@\" > {args_file}\n")
            (fakebin / "xcodebuild").chmod(0o755)
            (root / "Labstream" / "Existing.swift").write_text("// baseline\n")
            self.commit_all(root)

            asset_dir = root / "Labstream" / "Assets.xcassets" / "New.imageset"
            asset_dir.mkdir(parents=True)
            (asset_dir / "Contents.json").write_text("{}\n")
            env = os.environ.copy()
            env["PATH"] = f"{fakebin}:{env['PATH']}"
            subprocess.run(["scripts/xcodebuild-versioned.sh", "-project", "Labstream.xcodeproj"], cwd=root, env=env, check=True)
            args = (root / "xcodebuild-args.txt").read_text()
            self.assertRegex(args, r"LABSTREAM_BUILD_SLUG=.*-dirty")

    def test_ci_hygiene_rejects_pbx_file_reference_churn(self):
        with self.make_repo() as root:
            self.copy_script(root, "ci-hygiene.sh")
            (root / "README.md").write_text("# Test\n")
            (root / "docs").mkdir()
            (root / "docs" / "DEVELOPMENT.md").write_text("Development notes\n")
            (root / "Signing.xcconfig").write_text("// template\n")
            pbx = root / "Labstream.xcodeproj" / "project.pbxproj"
            pbx.parent.mkdir()
            pbx.write_text("".join([
                "// !$*UTF8*$!\n",
                "{\n",
                "\tobjects = {\n",
                "\t/* Begin PBXFileReference section */\n",
                "\t\tAA0000000000000000000005 /* Labstream.app */ = {isa = PBXFileReference; path = Labstream.app; };\n",
                "\t/* End PBXFileReference section */\n",
                "\t};\n",
                "}\n",
            ]))
            self.commit_all(root)

            pbx.write_text(pbx.read_text().replace(
                "\t/* End PBXFileReference section */",
                "\t\tBB0000000000000000000001 /* NewView.swift */ = {isa = PBXFileReference; path = NewView.swift; };\n\t/* End PBXFileReference section */",
            ))
            result = subprocess.run(["scripts/ci-hygiene.sh"], cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unexpected project.pbxproj file-reference/build-file churn", result.stderr)

    def test_worktree_sim_id_replaces_stale_simid_with_hashed_clone(self):
        with self.make_repo() as root:
            self.copy_script(root, "worktree-sim.sh")
            (root / ".simid").write_text("GOLDEN-0000-0000-0000-000000000000\n")
            (root / "Labstream" / "Existing.swift").write_text("// baseline\n")
            self.commit_all(root)
            with tempfile.TemporaryDirectory(prefix=f"{root.name}-linked-", dir=root.parent) as linked_tmp:
                linked = Path(linked_tmp)
                subprocess.run(["git", "worktree", "add", "-q", "-b", "feature/collision", str(linked)], cwd=root, check=True)
                (linked / ".simid").write_text("STALE-0000-0000-0000-000000000000\n")

                state = root / "xcrun-state"
                clone_name = root / "xcrun-clone-name"
                fakebin = root / "fakebin"
                fakebin.mkdir()
                (fakebin / "xcrun").write_text(textwrap.dedent(f"""\
                    #!/usr/bin/env bash
                    set -euo pipefail
                    state={state}
                    clone_name={clone_name}
                    if [ "$1 $2 $3" = "simctl list devices" ] && [ "${{4:-}}" = "-j" ]; then
                      if [ -f "$state" ]; then
                        extra=',{{"name":"vpwt-feature-collision-deadbeef","udid":"NEW-0000-0000-0000-000000000000","state":"Shutdown"}}'
                      else
                        extra=''
                      fi
                      printf '{{"devices":{{"com.apple.CoreSimulator.SimRuntime.xrOS-26-0":[{{"name":"Golden","udid":"GOLDEN-0000-0000-0000-000000000000","state":"Shutdown"}}%s]}}}}\n' "$extra"
                      exit 0
                    fi
                    if [ "$1 $2" = "simctl clone" ]; then
                      printf '%s\n' "$4" > "$clone_name"
                      printf '%s\n' cloned > "$state"
                      printf '%s\n' "NEW-0000-0000-0000-000000000000"
                      exit 0
                    fi
                    if [ "$1 $2" = "simctl shutdown" ] || [ "$1 $2" = "simctl boot" ]; then
                      exit 0
                    fi
                    echo "unexpected xcrun $*" >&2
                    exit 2
                    """))
                (fakebin / "xcrun").chmod(0o755)
                env = os.environ.copy()
                env["PATH"] = f"{fakebin}:{env['PATH']}"

                result = subprocess.run(["scripts/worktree-sim.sh", "id"], cwd=linked, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
                self.assertEqual(result.stdout.strip(), "NEW-0000-0000-0000-000000000000")
                self.assertIn("stale .simid", result.stderr)
                self.assertEqual((linked / ".simid").read_text().strip(), "NEW-0000-0000-0000-000000000000")
                generated_name = clone_name.read_text().strip()
                self.assertRegex(generated_name, r"^vpwt-feature-collision-[0-9a-f]{8}$")

    def test_deploy_masks_device_and_team_ids_by_default(self):
        device = "12345678-1234-1234-1234-123456789ABC"
        team = "TEAMID1234"
        with tempfile.TemporaryDirectory() as tmp:
            tmp_root = Path(tmp)
            home = tmp_root / "home"
            app = home / "Library" / "Developer" / "Xcode" / "DerivedData" / "Labstream-TEST" / "Build" / "Products" / "Debug-xros" / "Labstream.app"
            app.mkdir(parents=True)
            fakebin = tmp_root / "fakebin"
            fakebin.mkdir()
            (fakebin / "xcrun").write_text(textwrap.dedent(f"""\
                #!/usr/bin/env bash
                set -euo pipefail
                if [ "$1 $2 $3" = "devicectl list devices" ]; then
                  printf 'Vision Pro ({device}) available\n'
                  exit 0
                fi
                if [ "$1 $2 $3 $4" = "devicectl device install app" ]; then
                  printf 'installed on {device}\n'
                  exit 0
                fi
                echo "unexpected xcrun $*" >&2
                exit 2
                """))
            (fakebin / "codesign").write_text(f"#!/usr/bin/env bash\nprintf 'TeamIdentifier={team}\\n' >&2\n")
            (fakebin / "xcrun").chmod(0o755)
            (fakebin / "codesign").chmod(0o755)
            env = os.environ.copy()
            env.update({
                "PATH": f"{fakebin}:{env['PATH']}",
                "HOME": str(home),
                "VP_DEVICE_ID": device,
                "VP_DEVELOPMENT_TEAM": team,
            })

            masked = subprocess.run([str(REPO / "scripts" / "deploy-to-device.sh"), "--no-build"], cwd=REPO, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
            combined = masked.stdout + masked.stderr
            self.assertNotIn(device, combined)
            self.assertNotIn(team, combined)
            self.assertIn("1234…9ABC", combined)
            self.assertIn("TEAM…1234", combined)

            verbose = subprocess.run([str(REPO / "scripts" / "deploy-to-device.sh"), "--no-build", "--verbose"], cwd=REPO, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
            verbose_combined = verbose.stdout + verbose.stderr
            self.assertIn(device, verbose_combined)
            self.assertIn(team, verbose_combined)

    def test_deploy_build_uses_versioned_xcodebuild_args(self):
        device = "12345678-1234-1234-1234-123456789ABC"
        team = "TEAMID1234"
        with tempfile.TemporaryDirectory() as tmp:
            tmp_root = Path(tmp)
            home = tmp_root / "home"
            app = home / "Library" / "Developer" / "Xcode" / "DerivedData" / "Labstream-TEST" / "Build" / "Products" / "Debug-xros" / "Labstream.app"
            fakebin = tmp_root / "fakebin"
            fakebin.mkdir()
            args_file = tmp_root / "xcodebuild-args.txt"
            (fakebin / "xcodebuild").write_text(textwrap.dedent(f"""\
                #!/usr/bin/env bash
                set -euo pipefail
                printf '%s\n' "$@" > {args_file}
                mkdir -p {app}
                exit 0
                """))
            (fakebin / "xcrun").write_text(textwrap.dedent(f"""\
                #!/usr/bin/env bash
                set -euo pipefail
                if [ "$1 $2 $3" = "devicectl list devices" ]; then
                  printf 'Vision Pro ({device}) available\n'
                  exit 0
                fi
                if [ "$1 $2 $3 $4" = "devicectl device install app" ]; then
                  printf 'installed on {device}\n'
                  exit 0
                fi
                echo "unexpected xcrun $*" >&2
                exit 2
                """))
            (fakebin / "codesign").write_text(f"#!/usr/bin/env bash\nprintf 'TeamIdentifier={team}\\n' >&2\n")
            for tool in ("xcodebuild", "xcrun", "codesign"):
                (fakebin / tool).chmod(0o755)
            env = os.environ.copy()
            env.update({
                "PATH": f"{fakebin}:{env['PATH']}",
                "HOME": str(home),
                "VP_DEVICE_ID": device,
                "VP_DEVELOPMENT_TEAM": team,
            })

            subprocess.run([str(REPO / "scripts" / "deploy-to-device.sh")], cwd=REPO, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
            args = args_file.read_text()
            self.assertIn("LABSTREAM_BUILD_SLUG=", args)
            self.assertIn("LABSTREAM_BUILD_DATE_UTC=", args)
            self.assertIn("DEVELOPMENT_TEAM=TEAMID1234", args)


if __name__ == "__main__":
    unittest.main()
