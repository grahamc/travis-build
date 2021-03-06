require 'travis/build/addons/base'
require 'shellwords'

module Travis
  module Build
    class Addons
      class Apt < Base
        SUPER_USER_SAFE = true
        SUPPORTED_OPERATING_SYSTEMS = [
          /^linux.*/
        ].freeze
        SUPPORTED_DISTS = %w(
          precise
          trusty
          xenial
        ).freeze

        class << self
          def package_whitelists
            @package_whitelists ||= load_package_whitelists
          end

          def source_whitelists
            @source_whitelists ||= load_source_whitelists
          end

          private

          def load_package_whitelists(dists = SUPPORTED_DISTS)
            require 'faraday'
            loaded = { unset: [] }.merge(Hash[dists.map { |dist| [dist.to_sym, []] }])
            dists.each do |dist|
              response = fetch_package_whitelist(dist)
              loaded[dist.to_sym] = response.split.map(&:strip).sort.uniq
            end
            loaded
          rescue => e
            warn e unless ENV['ENV'] == 'test'
            loaded
          end

          def load_source_whitelists(dists = SUPPORTED_DISTS)
            require 'faraday'
            loaded = { unset: {} }.merge(Hash[dists.map { |dist| [dist.to_sym, {}] }])
            dists.each do |dist|
              response = fetch_source_whitelist(dist)
              entries = JSON.parse(response)
              loaded[dist.to_sym] = Hash[entries.reject { |e| !e.key?('alias') }.map { |e| [e.fetch('alias'), e] }]
            end
            loaded
          rescue => e
            warn e unless ENV['ENV'] == 'test'
            loaded
          end

          def fetch_package_whitelist(dist)
            Faraday.get(package_whitelist_url(dist)).body.to_s
          end

          def fetch_source_whitelist(dist)
            Faraday.get(source_whitelist_url(dist)).body.to_s
          end

          def package_whitelist_url(dist)
            Travis::Build.config.apt_package_whitelist[dist.downcase].to_s
          end

          def source_whitelist_url(dist)
            Travis::Build.config.apt_source_whitelist[dist.downcase].to_s
          end
        end

        def before_prepare?
          SUPPORTED_OPERATING_SYSTEMS.any? do |os_match|
            data[:config][:os].to_s =~ os_match
          end && SUPPORTED_DISTS.include?(data[:config][:dist].to_s)
        end

        def before_prepare
          sh.fold('apt') do
            add_apt_sources unless config_sources.empty?
            add_apt_packages unless config_packages.empty?
          end
        end

        def skip_whitelist?
          Travis::Build.config.apt_whitelist_skip?
        end

        def before_configure?
          config[:config] && config[:config][:retries]
        end

        def before_configure
          sh.echo "Configuring default apt-get retries", ansi: :yellow
          sh.raw <<~EOF
          if [[ -d /var/lib/apt/lists && -n $(command -v apt-get) ]]; then
            cat <<-EOS > 99-travis-build-retries
          Acquire {
            ForceIPv4 "1";
            Retries "5";
            https {
              Timeout "30";
            };
          };
          EOS
            sudo mv 99-travis-build-retries /etc/apt/apt.conf.d
          fi
          EOF
        end

        private

          def add_apt_sources
            sh.echo "Adding APT Sources (BETA)", ansi: :yellow

            whitelisted = []
            disallowed = []
            disallowed_while_sudo = []

            config_sources.each do |src|
              source = source_whitelists[config_dist][src]

              if source.respond_to?(:[]) && source['sourceline']
                whitelisted << source.clone
              elsif !(data.disable_sudo?) || skip_whitelist?
                if src.respond_to?(:has_key?)
                  if src.has_key?(:sourceline)
                    whitelisted << {
                      'sourceline' => src[:sourceline],
                      'key_url' => src[:key_url]
                    }
                  else
                    sh.echo "'sourceline' key missing:", ansi: :yellow
                    sh.echo Shellwords.escape(src.inspect)
                  end
                else
                  disallowed_while_sudo << src
                end
              elsif source.nil?
                disallowed << src
              end
            end

            unless disallowed.empty?
              sh.echo "Disallowing sources: #{disallowed.map { |source| Shellwords.escape(source) }.join(', ')}", ansi: :red
              sh.echo 'If you require these sources, please use `sudo: required` in your `.travis.yml` to manage APT sources.'
            end

            unless disallowed_while_sudo.empty?
              sh.echo "Disallowing sources: #{disallowed_while_sudo.map { |source| Shellwords.escape(source) }.join(', ')}", ansi: :red
              sh.echo "To add unlisted APT sources, follow instructions in " \
                "https://docs.travis-ci.com/user/installing-dependencies#Installing-Packages-with-the-APT-Addon"
            end

            unless whitelisted.empty?
              sh.export 'DEBIAN_FRONTEND', 'noninteractive', echo: true
              whitelisted.each do |source|
                sh.cmd "curl -sSL #{source['key_url'].untaint.inspect} | sudo -E apt-key add -", echo: true, assert: true, timing: true if source['key_url']
                if source['sourceline'].start_with? 'ppa:'
                  sh.cmd "sudo -E apt-add-repository -y #{source['sourceline'].untaint.inspect}", echo: true, assert: true, timing: true
                else
                  # Avoid adding deb-src lines to work around https://bugs.launchpad.net/ubuntu/+source/software-properties/+bug/987264
                  sh.cmd "echo #{source['sourceline'].untaint.inspect} | sudo tee -a /etc/apt/sources.list > /dev/null", echo: true, assert: true, timing: true
                end
              end
            end
          end

          def add_apt_packages
            sh.echo "Installing APT Packages (BETA)", ansi: :yellow

            whitelisted, disallowed = config_packages.partition { |pkg| package_whitelisted?(package_whitelists[config_dist] || [], pkg) }

            unless disallowed.empty?
              sh.echo "Disallowing packages: #{disallowed.map { |package| Shellwords.escape(package) }.join(', ')}", ansi: :red
              sh.echo 'If you require these packages, please review the package ' \
                'approval process at: ' \
                'https://github.com/travis-ci/apt-package-whitelist#package-approval-process'
            end

            unless whitelisted.empty?
              if whitelisted.any? {|pkg| pkg =~ /^postgresql/}
                stop_postgresql
              end

              sh.export 'DEBIAN_FRONTEND', 'noninteractive', echo: true
              sh.cmd "sudo -E apt-get -yq update &>> ~/apt-get-update.log", echo: true, timing: true
              apt_opt_cmd = <<~APT_OPTS_RETRIEVAL
              TRAVIS_APT_OPTS="$(
                apt-get --version | awk '
                  $1 == "apt" {
                    split($2, apt, ".")
                    if ((apt[1]==1 && apt[2]>2) || apt[1]>1) {
                      print "--allow-downgrades --allow-remove-essential --allow-change-held-packages"
                    }
                    else {print "--force-yes"}
                    exit
                  }
                '
              )"
              APT_OPTS_RETRIEVAL
              sh.raw apt_opt_cmd
              command = 'sudo -E apt-get -yq --no-install-suggests --no-install-recommends ' \
                "$TRAVIS_APT_OPTS install #{whitelisted.join(' ')}"
              sh.cmd command, echo: true, timing: true

              sh.raw "result=$?"
              sh.if '$result -ne 0' do
                sh.fold 'apt-get.diagnostics' do
                  sh.echo "apt-get install failed", ansi: :red
                  sh.cmd 'cat ~/apt-get-update.log', echo: true
                end
                sh.raw "TRAVIS_CMD='#{command}'"
                sh.raw "travis_assert $result"
                sh.raw 'unset TRAVIS_APT_OPTS'
              end
            end
          end

          def config
            @config ||= Hash(super)
          end

          def config_sources
            @config_sources ||= Array(config[:sources]).flatten.compact
          rescue TypeError => e
            if e.message =~ /no implicit conversion of Symbol into Integer/
              raise Travis::Build::AptSourcesConfigError.new
            end
          end

          def config_packages
            @config_packages ||= Array(config[:packages]).flatten.compact
          rescue TypeError => e
            if e.message =~ /no implicit conversion of Symbol into Integer/
              raise Travis::Build::AptPackagesConfigError.new
            end
          end

          def config_dist
            (data.config[:dist] || :unset).to_sym
          end

          def package_whitelisted?(list, pkg)
            list.include?(pkg) || !data.disable_sudo? || skip_whitelist?
          end

          def package_whitelists
            ::Travis::Build::Addons::Apt.package_whitelists
          end

          def source_whitelists
            ::Travis::Build::Addons::Apt.source_whitelists
          end

          def stop_postgresql
            sh.echo "PostgreSQL package is detected. Stopping postgresql service. See https://github.com/travis-ci/travis-ci/issues/5737 for more information.", ansi: :yellow
            command = <<~ENDOFBASH
              if [[ "$TRAVIS_INIT" == systemd ]]; then
                sudo systemctl stop postgresql
              else
                sudo service postgresql stop
              fi
            ENDOFBASH
            sh.cmd command, echo: true
          end
      end
    end
  end
end
