require "builder"

module Hudson
  class JobConfigBuilder
    attr_accessor :job_type
    attr_accessor :steps, :rubies
    attr_accessor :scm, :public_scm, :scm_branches
    attr_accessor :scm, :public_scm, :git_branches
    attr_accessor :assigned_node, :node_labels # TODO just one of these
    attr_accessor :envfile
    attr_accessor :gemset
    attr_accessor :rvm_home
    attr_accessor :email

    InvalidTemplate = Class.new(StandardError)

    VALID_JOB_TEMPLATES = %w[none rails rails3 ruby rubygem rakeci rvmrakeci]

    # +job_type+ - template of default steps to create with the job
    # +steps+ - array of [:method, cmd], e.g. [:build_shell_step, "bundle initial"]
    #   - Default is based on +job_type+.
    # +scm+           - URL to the repository. Currently only support git URLs.
    # +public_scm+    - convert the +scm+ URL to a publicly accessible URL for the Hudson job config.
    # +scm_branches+  - array of branches to run builds. Default: ['master']
    # +rubies+        - list of RVM rubies to run tests (via Hudson Axes).
    # +assigned_node+ - restrict this job to running on slaves with these labels (space separated)
    def initialize(job_type = :ruby, &block)
      self.job_type = job_type.to_s if job_type

      yield self

      self.scm_branches ||= ["master"]
      raise InvalidTemplate unless VALID_JOB_TEMPLATES.include?(job_type.to_s)
    end

    def builder
      b = Builder::XmlMarkup.new :indent => 2
      b.instruct!
      b.tag!(matrix_project? ? "matrix-project" : "project") do
        b.actions
        b.description
        b.logRotator do
          b.daysToKeep -1
          b.numToKeep 10
          b.artifactDaysToKeep -1
          b.artifactNumToKeep -1
        end
        b.keepDependencies false
        b.properties
        build_scm b
        b.assignedNode assigned_node if assigned_node
        b.canRoam !assigned_node
        b.disabled false
        b.blockBuildWhenUpstreamBuilding false
        b.triggers :class => "vector" do
          b.tag!("hudson.triggers.SCMTrigger") do
            b.spec "*/5 * * * *"
          end
        end
        b.concurrentBuild false
        build_axes b if matrix_project?
        build_steps b
        if email
          b.publishers do
            b.tag!("hudson.tasks.Mailer") do
              b.recipients email
              b.dontNotifyEveryUnstableBuild false
              b.sendToIndividuals false
            end
          end
        else
          b.publishers
        end
        build_wrappers b
        b.runSequentially false if matrix_project?
      end
    end

    def to_xml
      builder.to_s
    end

    protected

    # <scm class="hudson.plugins.git.GitSCM"> ... </scm>
    def build_scm(b)
      if scm && scm =~ /git/
        scm_url = public_scm ? public_only_git_scm(scm) : scm
        b.scm :class => "hudson.plugins.git.GitSCM" do
          b.configVersion 1
          b.remoteRepositories do
            b.tag! "org.spearce.jgit.transport.RemoteConfig" do
              b.string "origin"
              b.int 5
              b.string "fetch"
              b.string "+refs/heads/*:refs/remotes/origin/*"
              b.string "receivepack"
              b.string "git-upload-pack"
              b.string "uploadpack"
              b.string "git-upload-pack"
              b.string "url"
              b.string scm_url
              b.string "tagopt"
              b.string
            end
          end

          if scm_branches
            b.branches do
              scm_branches.each do |branch|
                b.tag! "hudson.plugins.git.BranchSpec" do
                  b.name branch
                end
              end
            end
          end

          b.localBranch
          b.mergeOptions
          b.recursiveSubmodules false
          b.doGenerateSubmoduleConfigurations false
          b.authorOrCommitter false
          b.clean false
          b.wipeOutWorkspace false
          b.buildChooser :class => "hudson.plugins.git.util.DefaultBuildChooser"
          b.gitTool "Default"
          b.submoduleCfg :class => "list"
          b.relativeTargetDir
          b.excludedRegions
          b.excludedUsers
        end
      end
    end

    def matrix_project?
      !(rubies.blank? && node_labels.blank?)
    end

    # <hudson.matrix.TextAxis>
    #   <name>RUBY_VERSION</name>
    #   <values>
    #     <string>1.8.7</string>
    #     <string>1.9.2</string>
    #     <string>rbx-head</string>
    #     <string>jruby</string>
    #   </values>
    # </hudson.matrix.TextAxis>
    # <hudson.matrix.LabelAxis>
    #   <name>label</name>
    #   <values>
    #     <string>1.8.7</string>
    #     <string>ubuntu</string>
    #   </values>
    # </hudson.matrix.LabelAxis>
    def build_axes(b)
      b.axes do
        unless rubies.blank?
          b.tag! "hudson.matrix.TextAxis" do
            b.name "RUBY_VERSION"
            b.values do
              rubies.each do |rvm_name|
                b.string rvm_name
              end
            end
          end
        end
        unless node_labels.blank?
          b.tag! "hudson.matrix.LabelAxis" do
            b.name "label"
            b.values do
              node_labels.each do |label|
                b.string label
              end
            end
          end
        end
      end
    end

    # Example:
    # <buildWrappers>
    #   <hudson.plugins.envfile.EnvFileBuildWrapper>
    #     <filePath>/path/to/env/file</filePath>
    #   </hudson.plugins.envfile.EnvFileBuildWrapper>
    # </buildWrappers>
    def build_wrappers(b)
      if envfile
        b.buildWrappers do
          self.envfile = [envfile] unless envfile.is_a?(Array)
          b.tag! "hudson.plugins.envfile.EnvFileBuildWrapper" do
            envfile.each do |file|
              b.filePath file
            end
          end
        end
      else
        b.buildWrappers
      end
    end

    # The important sequence of steps that are run to process a job build.
    # Can be defaulted by the +job_type+ using +default_steps(job_type)+,
    # or customized via +steps+ array.
    def build_steps(b)
      b.builders do
        self.steps ||= default_steps(job_type)
        steps.each do |step|
          method, cmd = step
          send(method.to_sym, b, cmd) # e.g. build_shell_step(b, "bundle install")
        end
      end
    end

    def default_steps(job_type)
      steps = case job_type.to_sym
      when :rakeci
        [
          [:build_shell_step, "#!/bin/bash -x\nbundle --without production --path=gems && bundle exec rake ci"]
        ]
      when :rvmrakeci
        [
          [:build_shell_step, "#!/bin/bash -x\nsource \"#{rvm_home}/.rvm/scripts/rvm\"\nrvm --create --rvmrc \"#{gemset}\"\nbundle --without production --path=gems && bundle exec rake ci"]
        ]
      when :rails, :rails3
        [
          [:build_shell_step, "bundle --without production --path=gems"],
          [:build_ruby_step, <<-RUBY.gsub(/^            /, '')],
            unless File.exist?("config/database.yml")
              require 'fileutils'
              example = Dir["config/database*"].first
              puts "Using \#{example} for config/database.yml"
              FileUtils.cp example, "config/database.yml"
            end
            RUBY
          [:build_shell_step, "bundle exec rake db:create:all"],
          [:build_shell_step, <<-RUBY.gsub(/^            /, '')],
            if [ -f db/schema.rb ]; then
              bundle exec rake db:schema:load
            else
              bundle exec rake db:migrate
            fi
            RUBY
          [:build_shell_step, "bundle exec rake"]
        ]
      when :ruby, :rubygems
        [
          [:build_shell_step, "bundle install"],
          [:build_shell_step, "bundle exec rake"]
        ]
      else
        [ [:build_shell_step, 'echo "THERE ARE NO STEPS! Except this one..."'] ]
      end
      rubies.blank? ? steps : default_rvm_steps + steps
    end

    def default_rvm_steps
      [
        [:build_shell_step, "rvm $RUBY_VERSION"],
        [:build_shell_step, "rvm gemset create ruby-$RUBY_VERSION && rvm gemset use ruby-$RUBY_VERSION"]
      ]
    end

    # <hudson.tasks.Shell>
    #   <command>echo &apos;THERE ARE NO STEPS! Except this one...&apos;</command>
    # </hudson.tasks.Shell>
    def build_shell_step(b, command)
      b.tag! "hudson.tasks.Shell" do
        begin
          b.command command.to_xs.gsub("&amp;", '&') #.gsub(%r{"}, '&quot;').gsub(%r{'}, '&apos;')
        rescue => e
          # e.g. 'Try running `bundle update rspec`'.match(/`(.*)`/)[1] will match: bundle update rspec
          if bundle_update_cmd = e.message.match(/`(.*)`/)[1]
            puts "Rescued bundler errror #{e.class}: #{e.message}, #{e.backtrace[0..15].join("\n")}"
            puts "Trying to update gems with '#{bundle_update_cmd}'"
            `#{bundle_update_cmd}`
            retry
          else
            raise
          end
        end
      end
    end

    # <hudson.plugins.ruby.Ruby>
    #   <command>unless File.exist?(&quot;config/database.yml&quot;)
    #   require &apos;fileutils&apos;
    #   example = Dir[&quot;config/database*&quot;].first
    #   puts &quot;Using #{example} for config/database.yml&quot;
    #   FileUtils.cp example, &quot;config/database.yml&quot;
    # end</command>
    # </hudson.plugins.ruby.Ruby>
    def build_ruby_step(b, command)
      b.tag! "hudson.plugins.ruby.Ruby" do
        b.command do
          b << command.to_xs.gsub(%r{"}, '&quot;').gsub(%r{'}, '&apos;')
        end
      end
    end

    # Usage: build_ruby_step b, "db:schema:load"
    #
    # <hudson.plugins.rake.Rake>
    #   <rakeInstallation>(Default)</rakeInstallation>
    #   <rakeFile></rakeFile>
    #   <rakeLibDir></rakeLibDir>
    #   <rakeWorkingDir></rakeWorkingDir>
    #   <tasks>db:schema:load</tasks>
    #   <silent>false</silent>
    # </hudson.plugins.rake.Rake>
    def build_rake_step(b, tasks)
      b.tag! "hudson.plugins.rake.Rake" do
        b.rakeInstallation "(Default)"
        b.rakeFile
        b.rakeLibDir
        b.rakeWorkingDir
        b.tasks tasks
        b.silent false
      end
    end

    # Converts git@github.com:drnic/newgem.git into git://github.com/drnic/newgem.git
    def public_only_git_scm(scm_url)
      if scm_url =~ /git@([\w\-_.]+):(.+)\.git/
        "git://#{$1}/#{$2}.git"
      else
        scm_url
      end
    end
  end
end
