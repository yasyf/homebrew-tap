# Homebrew formula for synckitd. Installs the prebuilt binary for the current
# platform from synckit's GitHub Releases — no Go toolchain needed.
# `brew install --HEAD` builds (pure Go) from source instead.
#
#   brew install yasyf/tap/synckitd
#
class Synckitd < Formula
  desc "Generic per-machine sync daemon for synckit consumers"
  homepage "https://github.com/yasyf/synckit"
  version "0.51.3"

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
      sha256 "0a2601538189453fb356eb0c1e1017817f996f2a8255002329c0f182405acc99"
    end
    on_intel do
      url "https://github.com/yasyf/synckit/releases/download/v#{version}/synckitd_#{version}_darwin_amd64.tar.gz"
      sha256 "9552c1897b4dcffe79a46c5494ab5c6e470eea5d4571252dc02e198abb532e73"
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
