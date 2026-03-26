require "fileutils"
require "tmpdir"

class JtLiveWhisper < Formula
  include Language::Python::Virtualenv

  desc "Fully local live transcription, translation, diarization, and meeting-summary toolkit"
  homepage "https://github.com/jasoncheng7115/jt-live-whisper"
  license "Apache-2.0"

  url "https://github.com/jasoncheng7115/jt-live-whisper.git",
      branch: "main",
      using: GitDownloadStrategy
  version "git-main"
  head "https://github.com/jasoncheng7115/jt-live-whisper.git", branch: "main"

  depends_on "git" => :build
  depends_on "pkgconf" => :build
  depends_on "rust" => :build
  depends_on "uv" => :build

  on_macos do
    if MacOS.version < :ventura
      depends_on "python@3.11"
    else
      depends_on "python@3.12"
    end
    depends_on "cmake" => :build
    depends_on "sdl2"
  end

  on_linux do
    depends_on "python@3.12"
    depends_on "cmake" => :build
    depends_on "portaudio"
    depends_on "sdl2"
  end

  def install
    unless ffmpeg_formula_installed?
      odie <<~EOS
        jt-live-whisper requires either `ffmpeg` or `ffmpeg-full` to already be installed.

        Install one of:
          brew install ffmpeg
          brew install ffmpeg-full
      EOS
    end

    libexec.install Dir["*"]
    deps_src = Pathname.new(__dir__) / "jt-live-whisper"
    deps_dir = libexec / "deps"
    deps_dir.rmtree if deps_dir.exist?
    FileUtils.cp_r(deps_src, deps_dir)

    py = if OS.mac? && MacOS.version < :ventura
      Formula["python@3.11"].opt_bin/"python3.11"
    else
      Formula["python@3.12"].opt_bin/"python3.12"
    end

    ENV.prepend_path "PATH", ffmpeg_opt_bin if ffmpeg_opt_bin
    ENV["PYTHONNOUSERSITE"] = "1"
    ENV["HF_HUB_DISABLE_TELEMETRY"] = "1"
    # build C/Rust extensions from source to avoid non-relocatable wheels
    if (ffmpeg_prefix = ffmpeg_opt_prefix)
      ENV.prepend_path "PKG_CONFIG_PATH", ffmpeg_prefix/"lib/pkgconfig"
      ENV.append "LDFLAGS", "-L#{ffmpeg_prefix}/lib"
      ENV.append "CPPFLAGS", "-I#{ffmpeg_prefix}/include"
    end
    ENV.append "LDFLAGS", "-Wl,-headerpad_max_install_names"
    ENV.append "RUSTFLAGS", "-C link-arg=-Wl,-headerpad_max_install_names"

    ENV["UV_PROJECT_ENVIRONMENT"] = (libexec/"venv").to_s
    sync_cmd = [
      "uv", "sync",
      "--python", py,
      "--project", deps_dir,
      "--no-dev",
    ]
    sync_cmd += ["--extra", "apple-silicon"] if OS.mac? && Hardware::CPU.arm?
    system(*sync_cmd)

    (libexec/"logs").mkpath
    (libexec/"recordings").mkpath
    (libexec/"whisper.cpp"/"models").mkpath
    var_dir.mkpath
    (var_dir/"hf-cache").mkpath
    (var_dir/"argos-translate"/"cache").mkpath
    (var_dir/"argos-translate"/"config").mkpath
    (var_dir/"argos-translate"/"packages").mkpath
    (var_dir/"models").mkpath

    ensure_whisper_cpp_built
    write_cli_entrypoint
    write_model_prefetch_script
    write_doctor_script
  end

  def post_install
    python = opt_libexec/"venv/bin/python3"
    return unless python.exist?

    link_home_data_dir
    system python, opt_libexec/"jt_live_whisper_prefetch_models.py"
    system python, opt_libexec/"jt_live_whisper_doctor.py", "--write-summary", summary_file
  end

  def post_uninstall
    link = home_data_link
    FileUtils.rm_f(link) if link.symlink? && link.readlink == var_dir
  end

  def caveats
    message = <<~EOS
      jt-live-whisper was installed into:
        #{opt_libexec}

      Run:
        jt-live-whisper

      Web UI:
        jt-live-whisper webui

      Diagnostics:
        jt-live-whisper doctor

      Model prefetch + environment summary:
    EOS

    if summary_file.exist?
      message += "\n#{summary_file.read}"
    else
      message += <<~EOS

        - summary file not generated yet
        - run `jt-live-whisper doctor` after install
      EOS
    end

    if OS.mac?
      message += <<~EOS

        macOS audio loopback:
          Homebrew formulae cannot auto-install casks as dependencies.
          If you need system-audio capture, install BlackHole separately:
            brew install --cask blackhole-2ch
      EOS
    else
      message += <<~EOS

        Linux audio loopback:
          Desktop audio routing is not bundled by this formula.
          CLI, file input, Web UI, and remote/GPU-server workflows are the safer defaults.
      EOS
    end

    message
  end

  test do
    assert_predicate opt_libexec/"translate_meeting.py", :exist?
    assert_predicate opt_libexec/"webui.py", :exist?
    assert_predicate opt_libexec/"venv", :exist?
    assert_predicate bin/"jt-live-whisper", :exist?
  end

  private

  def summary_file
    var/"jt-live-whisper/install-summary.txt"
  end

  def ffmpeg_formula_installed?
    formula_installed?("ffmpeg-full") || formula_installed?("ffmpeg")
  end

  def ffmpeg_opt_prefix
    if formula_installed?("ffmpeg-full")
      Formula["ffmpeg-full"].opt_prefix
    elsif formula_installed?("ffmpeg")
      Formula["ffmpeg"].opt_prefix
    end
  end

  def ffmpeg_opt_bin
    prefix = ffmpeg_opt_prefix
    prefix/"bin" if prefix
  end

  def formula_installed?(name)
    Formula[name].any_version_installed?
  rescue FormulaUnavailableError
    false
  end

  def var_dir
    var/"jt-live-whisper"
  end

  def home_data_link
    Pathname.new(File.expand_path("~/.local/share/jt-live-whisper"))
  end

  def whisper_dir
    libexec/"whisper.cpp"
  end

  def ensure_whisper_cpp_built
    models_backup = Dir.mktmpdir("jt-live-whisper-models")
    existing_models = whisper_dir/"models"
    if existing_models.directory? && !Dir.empty?(existing_models)
      FileUtils.cp_r Dir["#{existing_models}/*"], models_backup
    end

    FileUtils.rm_rf whisper_dir
    system "git", "clone", "--depth", "1", "https://github.com/ggerganov/whisper.cpp.git", whisper_dir

    restored_models = Dir["#{models_backup}/*"]
    unless restored_models.empty?
      FileUtils.mkdir_p whisper_dir/"models"
      FileUtils.cp_r restored_models, whisper_dir/"models"
    end

    gguf = whisper_dir/"ggml/src/gguf.cpp"
    if gguf.exist? && gguf.read.include?("errno") && !gguf.read.include?("#include <cerrno>")
      contents = gguf.read
      File.write(gguf, "#include <cerrno>\n#{contents}")
    end

    cmake_flags = ["-S", whisper_dir, "-B", whisper_dir/"build", "-DWHISPER_SDL2=ON"]
    cmake_flags << "-DCMAKE_PREFIX_PATH=#{Formula["sdl2"].opt_prefix}"
    if OS.mac? && Hardware::CPU.arm?
      cmake_flags << "-DWHISPER_METAL=ON"
      cmake_flags << "-DCMAKE_OSX_ARCHITECTURES=arm64"
      cmake_flags << "-DGGML_NATIVE=OFF"
      cmake_flags << "-DGGML_CPU_ARM_ARCH=armv8.5-a+fp16"
    elsif OS.mac?
      cmake_flags << "-DCMAKE_OSX_ARCHITECTURES=x86_64"
      cmake_flags << "-DGGML_METAL=OFF"
    end
    system "cmake", *cmake_flags
    system "cmake", "--build", whisper_dir/"build", "--target", "whisper-stream", "-j#{ENV.make_jobs}"
    system whisper_dir/"build/bin/whisper-stream", "--help"
  ensure
    FileUtils.rm_rf models_backup if models_backup && Dir.exist?(models_backup)
  end

  def link_home_data_dir
    link = home_data_link
    return if link.exist?
    parent = link.parent
    unless parent.writable?
      opoo "jt-live-whisper: home symlink skipped (#{parent} not writable; sandbox?) — create manually with: ln -s #{var_dir} #{link}"
      return
    end
    FileUtils.mkdir_p(parent)
    FileUtils.ln_s(var_dir, link)
  rescue Errno::EACCES, Errno::EPERM => e
    opoo "jt-live-whisper: failed to link #{link} -> #{var_dir}: #{e} (sandbox?) — create manually with: ln -s #{var_dir} #{link}"
  end

  def write_cli_entrypoint
    (bin/"jt-live-whisper").write <<~BASH
      #!/bin/bash
      set -euo pipefail

      SCRIPT_DIR="#{opt_libexec}"
      VAR_DIR="#{var_dir}"
      VENV_DIR="${SCRIPT_DIR}/venv"
      PYTHON_BIN="${VENV_DIR}/bin/python3"

      export PYTHONNOUSERSITE=1
      export HF_HUB_DISABLE_TELEMETRY=1
      export JT_LIVE_WHISPER_HOME="${SCRIPT_DIR}"
      export JT_LIVE_WHISPER_DATA="${VAR_DIR}"
      export HF_HOME="${VAR_DIR}/hf-cache"
      export HUGGINGFACE_HUB_CACHE="${VAR_DIR}/hf-cache"
      export XDG_DATA_HOME="${VAR_DIR}"
      export XDG_CACHE_HOME="${VAR_DIR}/argos-translate/cache"
      export XDG_CONFIG_HOME="${VAR_DIR}/argos-translate/config"
      export ARGOS_PACKAGES_DIR="${VAR_DIR}/argos-translate/packages"
      export JT_LIVE_WHISPER_NLLB_DIR="${VAR_DIR}/models/nllb-600m"
      export JT_LIVE_WHISPER_ARGOS_DIR="${VAR_DIR}/argos-translate/packages"
      export PATH="#{ffmpeg_opt_bin}:$PATH"

      if [ ! -x "${PYTHON_BIN}" ]; then
        echo "jt-live-whisper: missing virtualenv python at ${PYTHON_BIN}" >&2
        exit 1
      fi

      exec "${PYTHON_BIN}" "${SCRIPT_DIR}/jt_live_whisper_cli.py" "$@"
    BASH
    chmod 0755, bin/"jt-live-whisper"

    (libexec/"jt_live_whisper_cli.py").write <<~PYTHON
      #!/usr/bin/env python3
      import argparse
      import os
      import subprocess
      import sys

      ROOT = os.environ.get("JT_LIVE_WHISPER_HOME", os.path.dirname(os.path.abspath(__file__)))
      PYTHON = sys.executable
      TRANSLATE = os.path.join(ROOT, "translate_meeting.py")
      WEBUI = os.path.join(ROOT, "webui.py")
      DOCTOR = os.path.join(ROOT, "jt_live_whisper_doctor.py")

      def run_py(script, args):
          raise SystemExit(subprocess.call([PYTHON, script, *args], cwd=ROOT))

      parser = argparse.ArgumentParser(prog="jt-live-whisper")
      sub = parser.add_subparsers(dest="command")

      p_run = sub.add_parser("run", help="run translate_meeting.py")
      p_run.add_argument("args", nargs=argparse.REMAINDER)

      p_web = sub.add_parser("webui", help="run webui.py")
      p_web.add_argument("args", nargs=argparse.REMAINDER)

      p_doc = sub.add_parser("doctor", help="print environment and model status")
      p_doc.add_argument("args", nargs=argparse.REMAINDER)

      if len(sys.argv) > 1 and sys.argv[1] == "--webui":
          sys.argv = [sys.argv[0], "webui", *sys.argv[2:]]

      ns, unknown = parser.parse_known_args()

      if ns.command == "webui":
          run_py(WEBUI, ns.args + unknown)
      elif ns.command == "doctor":
          run_py(DOCTOR, ns.args + unknown)
      elif ns.command == "run":
          args = list(ns.args)
          if args and args[0] == "--":
              args = args[1:]
          run_py(TRANSLATE, args + unknown)
      else:
          run_py(TRANSLATE, sys.argv[1:])
    PYTHON
    chmod 0755, libexec/"jt_live_whisper_cli.py"
  end

  def write_model_prefetch_script
    (libexec/"jt_live_whisper_prefetch_models.py").write <<~PYTHON
      #!/usr/bin/env python3
      import json
      import os
      import platform
      import shutil
      import subprocess
      import sys
      import tempfile
      import urllib.request
      from pathlib import Path

      ROOT = Path(os.environ.get("JT_LIVE_WHISPER_HOME", "#{opt_libexec}"))
      VAR_DIR = Path("#{var_dir}")
      VAR_DIR.mkdir(parents=True, exist_ok=True)
      HF_CACHE = VAR_DIR / "hf-cache"
      HF_CACHE.mkdir(parents=True, exist_ok=True)
      ARGOS_BASE = VAR_DIR / "argos-translate"
      ARGOS_BASE.mkdir(parents=True, exist_ok=True)
      for p in [ARGOS_BASE / "cache", ARGOS_BASE / "config", ARGOS_BASE / "packages"]:
          p.mkdir(parents=True, exist_ok=True)
      MODELS_BASE = VAR_DIR / "models"
      MODELS_BASE.mkdir(parents=True, exist_ok=True)
      SUMMARY = VAR_DIR / "model-prefetch.json"
      TXT = VAR_DIR / "install-summary.txt"
      os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
      os.environ.setdefault("HF_HOME", str(HF_CACHE))
      os.environ.setdefault("HUGGINGFACE_HUB_CACHE", str(HF_CACHE))
      os.environ.setdefault("PYTHONNOUSERSITE", "1")
      os.environ.setdefault("XDG_DATA_HOME", str(ARGOS_BASE))
      os.environ.setdefault("XDG_CACHE_HOME", str(ARGOS_BASE / "cache"))
      os.environ.setdefault("XDG_CONFIG_HOME", str(ARGOS_BASE / "config"))
      os.environ.setdefault("ARGOS_PACKAGES_DIR", str(ARGOS_BASE / "packages"))

      results = {}

      def record(key, status, detail="", path=""):
          results[key] = {"status": status, "detail": detail, "path": str(path) if path else ""}

      def fetch_url(url, dest):
          dest = Path(dest)
          dest.parent.mkdir(parents=True, exist_ok=True)
          with urllib.request.urlopen(url) as r, open(dest, "wb") as f:
              shutil.copyfileobj(r, f)
          return dest

      def prefetch_whisper_cpp():
          dest = ROOT / "whisper.cpp" / "models" / "ggml-large-v3-turbo.bin"
          if dest.exists() and dest.stat().st_size > 0:
              record("whisper_cpp_large_v3_turbo", "ok", "already present", dest)
              return
          url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
          try:
              fetch_url(url, dest)
              record("whisper_cpp_large_v3_turbo", "ok", "downloaded", dest)
          except Exception as e:
              record("whisper_cpp_large_v3_turbo", "warn", repr(e), dest)

      def prefetch_nllb():
          try:
              from huggingface_hub import snapshot_download
              target = MODELS_BASE / "nllb-600m"
              target.mkdir(parents=True, exist_ok=True)
              snapshot_download(
                  repo_id="JustFrederik/nllb-200-distilled-600M-ct2-int8",
                  local_dir=str(target),
                  local_dir_use_symlinks=False,
              )
              record("nllb_600m", "ok", "ready", target)
          except Exception as e:
              record("nllb_600m", "warn", repr(e))

      def prefetch_argos():
          try:
              import argostranslate.package
              import argostranslate.translate
              index = argostranslate.package.get_available_packages()
              pkg = next((p for p in index if p.from_code == "en" and p.to_code == "zh"), None)
              if pkg is None:
                  raise RuntimeError("en->zh package not found in argos index")
              download_path = Path(pkg.download())
              argostranslate.package.install_from_path(str(download_path))
              download_path.unlink(missing_ok=True)
              installed = [f"{lang.code}:{lang.name}" for lang in argostranslate.translate.get_installed_languages()]
              record("argos_en_zh", "ok", ", ".join(installed), download_path)
          except Exception as e:
              record("argos_en_zh", "warn", repr(e))

      def prefetch_moonshine_if_needed():
          if platform.system() != "Darwin" or platform.machine() != "arm64":
              record("moonshine", "skip", "not Apple Silicon")
              return
          try:
              import huggingface_hub
              target = ROOT / "models" / "moonshine-base"
              huggingface_hub.snapshot_download(
                  repo_id="UsefulSensors/moonshine-base",
                  local_dir=str(target),
              )
              record("moonshine", "ok", "ready", target)
          except Exception as e:
              record("moonshine", "warn", repr(e))

      prefetch_whisper_cpp()
      prefetch_nllb()
      prefetch_argos()
      prefetch_moonshine_if_needed()

      SUMMARY.write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\\n", encoding="utf-8")

      lines = ["Model prefetch summary:"]
      for key, value in results.items():
          detail = value.get("detail", "")
          path = value.get("path", "")
          suffix = ""
          if detail:
              suffix += f" ({detail})"
          if path:
              suffix += f" [{path}]"
          lines.append(f"- {key}: {value['status']}{suffix}")
      TXT.write_text("\\n".join(lines) + "\\n", encoding="utf-8")

      failures = [k for k, v in results.items() if v.get("status") not in ("ok", "skip")]
      if failures:
          raise SystemExit(f"prefetch failed: {', '.join(failures)}")
    PYTHON
    chmod 0755, libexec/"jt_live_whisper_prefetch_models.py"
  end

  def write_doctor_script
    (libexec/"jt_live_whisper_doctor.py").write <<~PYTHON
      #!/usr/bin/env python3
      import argparse
      import json
      import os
      import platform
      import shutil
      import subprocess
      from pathlib import Path

      ROOT = Path(os.environ.get("JT_LIVE_WHISPER_HOME", "#{opt_libexec}"))
      VAR_DIR = Path("#{var}") / "jt-live-whisper"
      VAR_DIR.mkdir(parents=True, exist_ok=True)
      PREFETCH = VAR_DIR / "model-prefetch.json"

      def which(cmd):
          return shutil.which(cmd) or "not found"

      def detect_gpu():
          if shutil.which("nvidia-smi"):
              try:
                  out = subprocess.check_output(["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"], text=True).strip()
                  return f"NVIDIA: {out}" if out else "NVIDIA detected"
              except Exception as e:
                  return f"NVIDIA present but query failed: {e}"
          if platform.system() == "Darwin" and platform.machine() == "arm64":
              return "Apple Silicon integrated GPU/ANE path available"
          return "no dedicated GPU detected"

      def detect_blackhole():
          if platform.system() != "Darwin":
              return "n/a"
          candidates = [
              Path("/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver"),
              Path.home() / "Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver",
          ]
          return "installed" if any(p.exists() for p in candidates) else "not installed"

      def model_status():
          if PREFETCH.exists():
              try:
                  return json.loads(PREFETCH.read_text(encoding="utf-8"))
              except Exception as e:
                  return {"prefetch": {"status": "warn", "detail": repr(e)}}
          return {"prefetch": {"status": "warn", "detail": "prefetch summary missing"}}

      def render_summary():
          lines = []
          lines.append(f"- platform: {platform.system()} {platform.release()} ({platform.machine()})")
          lines.append(f"- python: {which('python3')}")
          lines.append(f"- ffmpeg: {which('ffmpeg')}")
          lines.append(f"- gpu: {detect_gpu()}")
          lines.append(f"- blackhole: {detect_blackhole()}")
          for key, value in model_status().items():
              detail = value.get("detail", "")
              path = value.get("path", "")
              suffix = ""
              if detail:
                  suffix += f" ({detail})"
              if path:
                  suffix += f" [{path}]"
              lines.append(f"- {key}: {value.get('status', 'unknown')}{suffix}")
          return "\\n".join(lines) + "\\n"

      parser = argparse.ArgumentParser()
      parser.add_argument("--write-summary")
      args, _ = parser.parse_known_args()
      summary = render_summary()
      print(summary, end="")
      if args.write_summary:
          Path(args.write_summary).write_text(summary, encoding="utf-8")
    PYTHON
    chmod 0755, libexec/"jt_live_whisper_doctor.py"
  end
end
