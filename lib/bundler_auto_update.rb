require "bundler_auto_update/version"

module Bundler
  module AutoUpdate
    class CLI
      def initialize(argv)
        @argv = argv
      end

      def run!
        Updater.new(test_command).auto_update!
      end

      # @return [String] Test command from @argv
      def test_command
        if @argv.first == '-c'
          @argv[1..-1].join(' ')
        end
      end
    end # class CLI

    class Updater
      DEFAULT_TEST_COMMAND = "rake"

      attr_reader :test_command, :do_not_update

      def initialize(test_command = nil)
        @test_command = test_command || DEFAULT_TEST_COMMAND
        @do_not_update = parse_do_not_update || {}
      end

      def auto_update!
        gemfile.gems.each do |gem|
          Logger.log ""
          if do_not_update[gem.name]
            Logger.log "Skipping #{gem.name}: gem appears in .donotupdate"
          else
            GemUpdater.new(gem, gemfile, test_command).auto_update
          end
        end
      end

      private

      def gemfile
        @gemfile ||= Gemfile.new
      end

      def parse_do_not_update
        return unless File.exist?(".donotupdate")
        do_not_update = {}
        File.read(".donotupdate").each_line do |l|
          l.gsub!(/\s+/, "")
          do_not_update[l] = true
        end
        do_not_update
      end
    end

    class GemUpdater
      attr_reader :gem, :gemfile, :test_command

      def initialize(gem, gemfile, test_command)
        @gem, @gemfile, @test_command = gem, gemfile, test_command
      end

      # Attempt to update to patch, then to minor then to major versions for gems with a version.
      # Attempt to perform the newest update for all other gems.
      def auto_update
        Logger.log "Updating #{gem.name}"
        if gem.version
          update_version(:patch) and update_version(:minor) and update_version(:major)
        else
          update()
        end
      end

      # Update current gem to latest :version_type:, run test suite and commit new Gemfile if successful.
      #
      # @param version_type :patch or :minor or :major
      # @return [Boolean] true on success or when already at latest version
      def update_version(version_type)
        new_version = gem.last_version(version_type)

        if new_version == gem.version
          Logger.log_indent "Current gem already at latest #{version_type} version. Passing this update."
          return true
        end

        Logger.log_indent "Updating to #{version_type} version #{new_version}"
        gem.version = new_version

        if update_gemfile and run_test_suite and commit_new_version
          true
        else
          revert_to_previous_version
          false
        end
      end

      def update
        Logger.log_indent "Updating to newest version"
        if update_gemfile and run_test_suite and commit_new_version
          true
        else
          revert_to_previous_version
          false
        end
      end

      private

      # Update gem version in Gemfile.
      #
      # @return true on success, false on failure.
      def update_gemfile
        if gemfile.update_gem(gem)
          Logger.log_indent "Gemfile updated successfully."
          true
        else
          Logger.log_indent "Failed to update Gemfile."
          false
        end
      end

      # @return true on success, false on failure
      def run_test_suite
        Logger.log_indent "Running test suite"
        if CommandRunner.system test_command
          Logger.log_indent "Test suite ran successfully."
          true
        else
          Logger.log_indent "Test suite failed to run."
          false
        end
      end

      def commit_new_version
        Logger.log_indent "Committing changes"
        commit_message = "Auto update #{gem.name}"
        if gem.version
          commit_message = "Auto update #{gem.name} to version #{gem.version}"
        end
        CommandRunner.system "git commit #{files_to_commit} -m '#{commit_message}'"
      end

      def files_to_commit
        @files_to_commit ||= if CommandRunner.system "git status | grep 'Gemfile.lock' > /dev/null"
                               "Gemfile Gemfile.lock"
                             else
                               "Gemfile"
                             end
      end

      def revert_to_previous_version
        Logger.log_indent "Reverting changes"
        CommandRunner.system "git checkout #{files_to_commit}"
        gemfile.reload!
      end
    end # class GemUpdater

    class Gemfile

      # Regex that matches a gem definition line.
      #
      # @return [RegEx] matching [_, name, _, version_info, _, options]
      def gem_line_regex(gem_name = '([\w-]+)')
        /^\s*gem\s*['"]#{gem_name}['"]\s*(,\s*['"](.+)['"])*\s*(,\s*(.*))?\n?$/
      end

      def gems
        gems = []

        content.dup.each_line do |l|
          if match = l.match(gem_line_regex)
            _, name, _, _, options, = match.to_a
            gems << Dependency.new(name, options)
          end
        end

        gems
      end

      # Update Gemfile and run 'bundle update'
      def update_gem(gem)
        old_path = GemVersionReader.get_path(gem)
        update_content(gem) and write if gem.version
        if CommandRunner.system("bundle update #{gem.name} --quiet")
          new_path = GemVersionReader.get_path(gem)
          new_path != old_path
        end
      end

      # @return [String] Gemfile content
      def content
        @content ||= read
      end

      # Reload Gemfile content
      def reload!
        @content = read
      end

      private

      def update_content(gem)
        new_content = ""
        content.each_line do |l|
          if l =~ gem_line_regex(gem.name)
            l = "gem '#{gem.name}', '#{gem.version}'#{gem.options}"
            puts l
          end
          new_content += l
        end

        @content = new_content
      end

      # @return [String] Gemfile content read from filesystem
      def read
        File.read('Gemfile')
      end

      # Write content to Gemfile
      def write
        File.open('Gemfile', 'w') do |f|
          f.write(content)
        end
      end
    end # class Gemfile

    class Logger
      def self.log(msg, prefix = "")
        puts prefix + msg
      end

      # Log with indentation:
      # "  - Log message"
      #
      def self.log_indent(msg)
        log(msg, "  - ")
      end

      # Log command:
      # "  > bundle update"
      #
      def self.log_cmd(msg)
        log(msg, "    > ")
      end
    end

    class Dependency
      attr_reader :name, :options, :major, :minor, :patch
      attr_accessor :version

      def initialize(name, options)
        @name = name
        @options = options
        @version = GemVersionReader.parse_gem_version(self)
        @major, @minor, @patch = @version.split('.') if @version
      end

      # Return last version scoped at :version_type:.
      #
      # Example: last_version(:patch), returns the last patch version
      # for the current major/minor version
      #
      # @return [String] last version. Ex: '1.2.3'
      #
      def last_version(version_type)
        case version_type
        when :patch
          available_versions.select { |v| v =~ /^#{major}\.#{minor}\D/ }.first
        when :minor
          available_versions.select { |v| v =~ /^#{major}\./ }.first
        when :major
          available_versions.first
        else
          raise "Invalid version_type: #{version_type}"
        end
      end

      # Return an ordered array of all available versions.
      #
      # @return [Array] of [String].
      def available_versions
        return unless @version
        the_gem_line = gem_remote_list_output.scan(/^#{name}\s.*$/).first
        the_gem_line.scan /\d+\.\d+\.\d+/
      end

      private

      def gem_remote_list_output
        @gem_remote_list_output ||= CommandRunner.run "gem list #{name} -r -a"
      end
    end # class Dependency

    class GemVersionReader

      def self.parse_gem_version(gem)
        regex = /.+\s#{gem.name}\s+\(([\d\.]+)\)/
        match = old_gem_versions.match(regex)
        match.to_a[1]
      end

      def self.get_path(gem)
        CommandRunner.run "bundle show #{gem.name}"
      end

      def self.old_gem_versions
        @@old_gem_versions ||= CommandRunner.run "bundle show"
      end

      private_class_method :old_gem_versions
    end

    class CommandRunner

      # Output the command about to run, and run it using system.
      #
      # @return true on success, false on failure
      def self.system(cmd)
        Logger.log_cmd cmd

        Kernel.system cmd
      end

      # Run a system command and return its output.
      def self.run(cmd)
        `#{cmd}`
      end
    end
  end # module AutoUpdate
end # module Bundler
