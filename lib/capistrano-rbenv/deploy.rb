module Capistrano
  module RbEnv
    def self.extended(configuration)
      configuration.load {
        namespace(:rbenv) {
          _cset(:rbenv_path) {
            capture("echo $HOME/.rbenv").chomp()
          }
          _cset(:rbenv_bin) {
            File.join(rbenv_path, 'bin', 'rbenv')
          }
          _cset(:rbenv_cmd) {
            rbenv_system_binpath.empty? ? "#{rbenv_bin}" : "#{sudo} -E #{rbenv_bin}"
          }
          _cset(:rbenv_repository, 'git://github.com/sstephenson/rbenv.git')
          _cset(:rbenv_branch, 'master')

          _cset(:rbenv_plugins, {
            'ruby-build' => 'git://github.com/sstephenson/ruby-build.git',
          })
          _cset(:rbenv_plugins_options, {
            'ruby-build' => {:branch => 'master'},
          })
          _cset(:rbenv_plugins_path) {
            File.join(rbenv_path, 'plugins')
          }

          _cset(:rbenv_git) {
            if scm == :git
              if fetch(:scm_command, :default) == :default
                fetch(:git, 'git')
              else
                scm_command
              end
            else
              fetch(:git, 'git')
            end
          }

          _cset(:rbenv_ruby_version, '1.9.3-p194')

          _cset(:rbenv_use_bundler, true)
          set(:bundle_cmd) { # override bundle_cmd in "bundler/capistrano"
            rbenv_use_bundler ? "#{rbenv_cmd} exec bundle" : 'bundle'
          }

          _cset(:shell_source_files) {
            %w[ .bashrc .zshrc .profile .bash_profile ]
          }

          _cset(:rbenv_system_binpath) { '' }

          desc("Setup rbenv.")
          task(:setup, :except => { :no_release => true }) {
            dependencies
            update
            configure
            build
            setup_bundler if rbenv_use_bundler
          }
          after 'deploy:setup', 'rbenv:setup'

          def _rbenv_sync(repository, destination, revision, system_bin=true)
            git = rbenv_git
            remote = 'origin'
            verbose = "-q"
            script = <<-E
              if test -d #{destination}; then
                cd #{destination} && #{git} fetch #{verbose} #{remote} && #{git} fetch --tags #{verbose} #{remote} && #{git} merge #{verbose} #{remote}/#{revision};
              else
                #{git} clone #{verbose} #{repository} #{destination} && cd #{destination} && #{git} checkout #{verbose} #{revision};
              fi;
              if [ ! "x#{rbenv_system_binpath}" = "x" ]; then
                for bin in $(ls #{destination}/bin);
                do
                  cd #{rbenv_system_binpath} && ln -nfs #{destination}/bin/$bin .;
                done;
              fi;
            E
            tmp_script = '/tmp/rbenv_sync.sh'
            put script, tmp_script
            rbenv_system_binpath.empty? ? run("sh #{tmp_script}") : run("#{sudo} sh #{tmp_script}")
          end

          desc("Update rbenv installation.")
          task(:update, :except => { :no_release => true }) {
            _rbenv_sync(rbenv_repository, rbenv_path, rbenv_branch)
            plugins.update
          }

          desc("Purge rbenv.")
          task(:purge, :except => { :no_release => true }) {
            run("rm -rf #{rbenv_path}")
          }

          namespace(:plugins) {
            desc("Update rbenv plugins.")
            task(:update, :except => { :no_release => true }) {
              rbenv_plugins.each { |name, repository|
                options = ( rbenv_plugins_options[name] || {})
                branch = ( options[:branch] || 'master' )
                _rbenv_sync(repository, File.join(rbenv_plugins_path, name), branch, system_bin=false)
              }
            }
          }

          task(:configure, :except => { :no_release => true }) {
            configure = <<-E
              for source_file in #{shell_source_files.join(' ')}
              do
                source_file=$HOME/$source_file
                touch $source_file
                last_line=$(tail -1 $source_file | grep . -c)
                [ "x$last_line" = "x1" ] && echo >> $source_file

                included=$(egrep "PATH=(.*)#{rbenv_path}/bin" $source_file)
                if [ "x$included" = "x"  ]; then
                  echo "export PATH=\\\$PATH:#{rbenv_path}/bin" >> $source_file
                fi
                included=$(egrep "eval(.*)rbenv init -" $source_file)
                if [ "x$included" = "x"  ]; then
                  echo "eval \\\"\\\$(rbenv init -)\\\"" >> $source_file
                fi
                included=$(egrep "export(.*)RBENV_ROOT" $source_file)
                if [ ! "x$included" = "x"  ]; then
                  sed -i '/export.*RBENV_ROOT/d' $source_file
                fi
                echo "export RBENV_ROOT=#{rbenv_path}" >> $source_file
              done
            E
            tmp_conf = "/tmp/configure_rbenv.sh"
            put configure, tmp_conf
            command = "sh #{tmp_conf} && #{sudo} sh #{tmp_conf} && rm #{tmp_conf}"
            run command
          }

          _cset(:rbenv_platform) {
            capture((<<-EOS).gsub(/\s+/, ' ')).strip
              if test -f /etc/debian_version; then
                if test -f /etc/lsb-release && grep -i -q DISTRIB_ID=Ubuntu /etc/lsb-release; then
                  echo ubuntu;
                else
                  echo debian;
                fi;
              elif test -f /etc/redhat-release; then
                echo redhat;
              else
                echo unknown;
              fi;
            EOS
          }
          _cset(:rbenv_ruby_dependencies) {
            case rbenv_platform
            when /(debian|ubuntu)/i
              %w(git-core build-essential libreadline6-dev zlib1g-dev libssl-dev bison)
            when /redhat/i
              %w(git-core autoconf glibc-devel patch readline readline-devel zlib zlib-devel openssl bison)
            else
              []
            end
          }
          task(:dependencies, :except => { :no_release => true }) {
            unless rbenv_ruby_dependencies.empty?
              case rbenv_platform
              when /(debian|ubuntu)/i
                run("#{sudo} apt-get install -q -y #{rbenv_ruby_dependencies.join(' ')}")
              when /redhat/i
                run("#{sudo} yum install -q -y #{rbenv_ruby_dependencies.join(' ')}")
              else
                # nop
              end
            end
          }

          desc("Build ruby within rbenv.")
          task(:build, :except => { :no_release => true }) {
            ruby = fetch(:rbenv_ruby_cmd, 'ruby')
            if rbenv_ruby_version != 'system'
              _sudo = rbenv_system_binpath.empty? ? '' : "#{sudo} -E"
              run("#{rbenv_cmd} whence #{ruby} | grep -q #{rbenv_ruby_version} || #{_sudo} #{rbenv_cmd} install #{rbenv_ruby_version}")
            end
            run("#{rbenv_cmd} exec #{ruby} --version")
          }

          _cset(:rbenv_bundler_gem, 'bundler')
          task(:setup_bundler, :except => { :no_release => true }) {
            gem = "#{rbenv_cmd} exec gem"
            if v = fetch(:rbenv_bundler_version, nil)
              q = "-n #{rbenv_bundler_gem} -v #{v}"
              f = "grep #{rbenv_bundler_gem} | grep #{v}"
              i = "-v #{v} #{rbenv_bundler_gem}"
            else
              q = "-n #{rbenv_bundler_gem}"
              f = "grep #{rbenv_bundler_gem}"
              i = "#{rbenv_bundler_gem}"
            end
            run("unset -v GEM_HOME; #{gem} query #{q} 2>/dev/null | #{f} || #{gem} install -q #{i}")
            run("#{rbenv_cmd} rehash && #{bundle_cmd} version")
          }
        }
      }
    end
  end
end

if Capistrano::Configuration.instance
  Capistrano::Configuration.instance.extend(Capistrano::RbEnv)
end

# vim:set ft=ruby ts=2 sw=2 :
