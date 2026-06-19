# Homebrew formula for cc-notes. Installs the prebuilt binary for the
# current platform from cc-notes' GitHub Releases — no Go toolchain
# needed. `brew install --HEAD` builds (pure Go) from source instead.
#
#   brew install yasyf/tap/cc-notes
#
# The FUSE-capable build ships everywhere one is published (macOS both
# arches, linux/amd64) and runs fine without FUSE present — only
# `cc-notes mount` needs fuse-t (macOS) or fuse3 (Linux) at runtime. If
# asset names or the fuse matrix change, scripts/install.sh and the
# bump-formula seds in .github/workflows/release.yml (in cc-notes) must
# change in lockstep.
#
# This file is generated and pushed by cc-notes' release.yml bump-formula
# job on every stable tag; edit the template there, not here.
class CcNotes < Formula
  desc "Git-native notes and tasks layer for agents"
  homepage "https://github.com/yasyf/cc-notes"
  version "0.7.3"
  license "PolyForm-Noncommercial-1.0.0"

  livecheck do
    url :stable
    strategy :github_latest
  end

  head do
    url "https://github.com/yasyf/cc-notes.git", branch: "main"
    depends_on "go" => :build
  end

  on_macos do
    on_arm do
      url "https://github.com/yasyf/cc-notes/releases/download/v#{version}/cc-notes_darwin_arm64_fuse"
      sha256 "87bebfcfd87b9d86b7fcfea2b6f29672233e8a33850bc5740ee660223a97adcd" # darwin-arm64
    end
    on_intel do
      url "https://github.com/yasyf/cc-notes/releases/download/v#{version}/cc-notes_darwin_amd64_fuse"
      sha256 "94da315b437e0136b123390c61fe1a72351914fc8712197a63267ba9572d63f5" # darwin-amd64
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/yasyf/cc-notes/releases/download/v#{version}/cc-notes_linux_amd64_fuse"
      sha256 "fad052cd25d7e6c5ea8289c285e551d26ad8ee64983d058f11f46e0cebcbd6b5" # linux-amd64
    end
    on_arm do
      # No FUSE variant ships for linux/arm64; this is the pure binary.
      url "https://github.com/yasyf/cc-notes/releases/download/v#{version}/cc-notes_linux_arm64"
      sha256 "f729475b84ac8c9114e21bc9954a11b9079d8e91d399ffb6bcbb817010958474" # linux-arm64
    end
  end

  def install
    if build.head?
      ENV["CGO_ENABLED"] = "0"
      ldflags = "-s -w -X github.com/yasyf/cc-notes/internal/version.Version=#{version}"
      system "go", "build", *std_go_args(ldflags: ldflags, output: bin/"cc-notes"), "./cmd/cc-notes"
    else
      # The release asset is a bare binary staged under its asset name.
      bin.install Dir["cc-notes_*"].first => "cc-notes"
    end
  end

  def caveats
    on_macos do
      <<~EOS
        `cc-notes mount` needs fuse-t at runtime:
          brew install macos-fuse-t/cask/fuse-t
        Everything else works without it.
      EOS
    end
  end

  test do
    # Release binaries print "<tag> (<commit>)", e.g. "v0.2.0 (ab12cd3)".
    assert_match version.to_s, shell_output("#{bin}/cc-notes version")
  end
end
