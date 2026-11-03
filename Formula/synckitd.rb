# Homebrew formula for synckitd. Installs the prebuilt binary for the current
# platform from synckit's GitHub Releases — no Go toolchain needed.
# `brew install --HEAD` builds (pure Go) from source instead.
#
#   brew install yasyf/tap/synckitd
#
class Synckitd < Formula
  desc "Generic per-machine sync daemon for synckit consumers"
  homepage "https://github.com/yasyf/synckit"
  version "0.52.0"

  depends_on :macos

  livecheck do
    url :stable
    strategy :github_latest
  end

  head do
    url "https://github.com/yasyf/synckit.git", branch: "main"
    depends_on "go" => :build
  end

  on_macos do
    on_arm do
      url "https://github.com/yasyf/synckit/releases/download/v#{version}/synckitd_#{version}_darwin_arm64.tar.gz"
      sha256 "295190e9eb82db26d4026133031bbe8a1d7fb425f07dc02bb6946adbbdabd80a"
    end
    on_intel do
      url "https://github.com/yasyf/synckit/releases/download/v#{version}/synckitd_#{version}_darwin_amd64.tar.gz"
      sha256 "dc2b93b3b694e6a35dc85af61528fbfc4a597545a751192698c33cd3d39d1995"
    end
  end

  def install
    if build.head?
      ENV["CGO_ENABLED"] = "0"
      ldflags = "-s -w -X main.version=#{version}"
      system "go", "build", *std_go_args(ldflags: ldflags, output: bin/"synckitd"), "./cmd/synckitd"
    else
      # brew auto-extracts the release tarball; install the bare binary.
      bin.install "synckitd"
    end
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/synckitd --version")
  end
end
