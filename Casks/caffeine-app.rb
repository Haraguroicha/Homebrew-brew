cask "caffeine-app" do
  name "Caffeine"
  desc "Keeps your Mac awake. Caffeine is a tiny open source program that puts an icon in the right side of your menubar. Click it to prevent your Mac from automatically going to sleep, dimming the screen or starting screen savers."

  on_monterey do
    version "1.2.1"
    sha256 "a256120d17983c89de3bdacd97f3e84e488c9782e6b2365ced365593a29beee5"
  end
  on_ventura do
    version "1.3.0"
    sha256 "201f3de57b11e1faec3307f00fb81ecab8ed2c433e94010de88b1edc4edbd15f"
  end
  on_sonoma do
    version "1.4.1"
    sha256 "d96b375d0eb01f6cbce1f49e70fa484facf8be0236350f677249bacb7fe9cb87"
  end

  homepage "https://www.caffeine-app.net/?macos=#{MacOS.full_version.pretty_name.downcase}"
  url "https://www.caffeine-app.net/download/#{MacOS.full_version.pretty_name.downcase}"

  app "Caffeine.app"
end
