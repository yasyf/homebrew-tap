# This file was rendered from an exact public release. DO NOT EDIT.
# Source: yasyf/cc-orchestrate@4b63e17444200d1433ffb1aa1834b2357cf76c5b (.goreleaser.yaml)
cask "cc-orchestrate" do
  binary "cc-orchestrate", target: "cco"

  version "0.10.1"

  on_macos do
    on_intel do
      sha256 "3ca38e075188108db2661d36b60428ec9dbd8c4051a06aed8e71c01789c6d780"
      url "https://github.com/yasyf/cc-orchestrate/releases/download/v0.10.1/cc-orchestrate_0.10.1_darwin_amd64.tar.gz"
    end
    on_arm do
      sha256 "a997bdf6b128ef46e7d6e0d3add01172097425f8280f66762843a7b78b3b3f8c"
      url "https://github.com/yasyf/cc-orchestrate/releases/download/v0.10.1/cc-orchestrate_0.10.1_darwin_arm64.tar.gz"
    end
  end

  on_linux do
    on_intel do
      sha256 "99384358e8bfcebaaecd9d95404275978f0fc27376c3bcdd74500b8823acb5b7"
      url "https://github.com/yasyf/cc-orchestrate/releases/download/v0.10.1/cc-orchestrate_0.10.1_linux_amd64.tar.gz"
    end
    on_arm do
      sha256 "8082755b26c6f652bb87310344fd791cc08b5e3b1d1e00323aa8698c2fdcff76"
      url "https://github.com/yasyf/cc-orchestrate/releases/download/v0.10.1/cc-orchestrate_0.10.1_linux_arm64.tar.gz"
    end
  end

  name "cc-orchestrate"
  desc "Orchestrate fleets of Claude Code agents across pluggable backends."
  homepage "https://github.com/yasyf/cc-orchestrate"

  livecheck do
    skip "Auto-generated on release."
  end
  binary "cc-orchestrate"

  # No zap stanza required
end
