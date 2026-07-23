# This file was rendered from an exact public release. DO NOT EDIT.
# Source: yasyf/cc-guides@a4080541460b491a35fd5746fccd12ee715b1aa2 (.goreleaser.yaml)
cask "cc-guides" do
  version "0.1.49"

  on_macos do
    on_intel do
      sha256 "81236a276c52b17f2d14b1629612a252039d633e3e6fb0e00e92410212b2765d"
      url "https://github.com/yasyf/cc-guides/releases/download/v0.1.49/cc-guides_0.1.49_darwin_amd64.tar.gz"
    end
    on_arm do
      sha256 "e0ecc4b26849d1aadb4327aaeab98716507405d7c2a62dabf4fb3fc9cd1655a5"
      url "https://github.com/yasyf/cc-guides/releases/download/v0.1.49/cc-guides_0.1.49_darwin_arm64.tar.gz"
    end
  end

  on_linux do
    on_intel do
      sha256 "6a5b609be592bbb04436384dd778f63bbac42355b5c1235e9c4db30c0004317a"
      url "https://github.com/yasyf/cc-guides/releases/download/v0.1.49/cc-guides_0.1.49_linux_amd64.tar.gz"
    end
    on_arm do
      sha256 "343990330352cd109a7930fe77c504caed90b7e94bef32c6a3636b56765ca9c9"
      url "https://github.com/yasyf/cc-guides/releases/download/v0.1.49/cc-guides_0.1.49_linux_arm64.tar.gz"
    end
  end

  name "cc-guides"
  desc "Canonical agent guides as a shipped Go binary \u2014 render AGENTS.md, CLAUDE.md, and shell artifacts from embedded, versioned fragments"
  homepage "https://github.com/yasyf/cc-guides"

  livecheck do
    skip "Auto-generated on release."
  end
  binary "cc-guides"

  # No zap stanza required
end
