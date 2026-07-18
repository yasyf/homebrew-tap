# Rendered by release-bun.yml from .github/formula/cc-pane.rb.tmpl — edit the template, not the tap copy.
cask "cc-pane" do
  version "0.1.0"

  on_macos do
    on_arm do
      sha256 "6802998a425fe5dc2bcdd5106dc0375cf8fb330bbe9194589ae8854e39d059b9"
      url "https://github.com/yasyf/cc-pane/releases/download/v#{version}/cc-pane-v#{version}-darwin-arm64.zip"
    end
    on_intel do
      sha256 "60bd73a89a78ee57848768958e489cf2715f543a0f779c41e75511db2b4875c7"
      url "https://github.com/yasyf/cc-pane/releases/download/v#{version}/cc-pane-v#{version}-darwin-x64.zip"
    end
  end

  on_linux do
    on_arm do
      sha256 "0028874a1923e1a755e9acef51122f2edddbacbd5c53252cedaef6745d37d46d"
      url "https://github.com/yasyf/cc-pane/releases/download/v#{version}/cc-pane-v#{version}-linux-arm64.zip"
    end
    on_intel do
      sha256 "21894e24592469035b7591a7d79c1623ac02b821d9ee9744659808f831e46267"
      url "https://github.com/yasyf/cc-pane/releases/download/v#{version}/cc-pane-v#{version}-linux-x64.zip"
    end
  end

  name "cc-pane"
  desc "Your whole Claude Code fleet in one pane of glass"
  homepage "https://github.com/yasyf/cc-pane"

  depends_on cask: "cc-orchestrate"
  depends_on formula: "cc-notes"

  binary "cc-pane"

  postflight do
    if OS.mac?
      system_command "/usr/bin/xattr",
                     args: ["-dr", "com.apple.quarantine", "#{staged_path}/cc-pane"]
    end
  end

  livecheck do
    skip "Auto-generated on release."
  end
end
