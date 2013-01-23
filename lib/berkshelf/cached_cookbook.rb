require 'chef/checksum_cache'
require 'chef/cookbook/syntax_check'

module Berkshelf
  # @author Jamie Winsor <jamie@vialstudios.com>
  class CachedCookbook
    class << self
      # Creates a new instance of Berkshelf::CachedCookbook from a path on disk that
      # contains a Cookbook. The name of the Cookbook will be determined first by the
      # name attribute of the metadata.rb file if it is present. If the name attribute
      # has not been set the Cookbook name will be determined by the basename of the
      # given filepath.
      #
      # @param [#to_s] path
      #   a path on disk to the location of a Cookbook
      #
      # @return [Berkshelf::CachedCookbook]
      def from_path(path)
        path = Pathname.new(path)
        metadata = Chef::Cookbook::Metadata.new

        begin
          metadata.from_file(path.join("metadata.rb").to_s)
        rescue IOError
          raise CookbookNotFound, "No 'metadata.rb' file found at: '#{path}'"
        end

        name = metadata.name.empty? ? File.basename(path) : metadata.name
        metadata.name name if metadata.name.empty?

        new(name, path, metadata)
      end

      # @param [#to_s] path
      #   a path on disk to the location of a Cookbook downloaded by the Downloader
      #
      # @return [CachedCookbook]
      #   an instance of CachedCookbook initialized by the contents found at the
      #   given path.
      def from_store_path(path)
        path = Pathname.new(path)
        cached_name = File.basename(path.to_s).slice(DIRNAME_REGEXP, 1)
        return nil if cached_name.nil?

        metadata = Chef::Cookbook::Metadata.new

        begin
          metadata.from_file(path.join("metadata.rb").to_s)
        rescue IOError
          raise CookbookNotFound, "No 'metadata.rb' file found at: '#{path}'"
        end
        
        metadata.name cached_name if metadata.name.empty?

        new(cached_name, path, metadata)
      end

      # @param [String] filepath
      #   a path on disk to the location of a file to checksum
      #
      # @return [String]
      #   a checksum that can be used to uniquely identify the file understood
      #   by a Chef Server.
      def checksum(filepath)
        Chef::ChecksumCache.generate_md5_checksum_for_file(filepath)
      end
    end

    DIRNAME_REGEXP = /^(.+)-(.+)$/
    CHEF_TYPE = "cookbook_version".freeze
    CHEF_JSON_CLASS = "Chef::CookbookVersion".freeze

    extend Forwardable

    attr_reader :cookbook_name
    attr_reader :path
    attr_reader :metadata

    # @return [Mash]
    #   a Mash containing Cookbook file category names as keys and an Array of Hashes
    #   containing metadata about the files belonging to that category. This is used
    #   to communicate what a Cookbook looks like when uploading to a Chef Server.
    #
    #   example:
    #     {
    #       :recipes => [
    #         {
    #           name: "default.rb",
    #           path: "recipes/default.rb",
    #           checksum: "fb1f925dcd5fc4ebf682c4442a21c619",
    #           specificity: "default"
    #         }
    #       ]
    #       ...
    #       ...
    #     }
    attr_reader :manifest

    def_delegator :@metadata, :version

    def initialize(name, path, metadata)
      @cookbook_name = name
      @path = Pathname.new(path)
      @metadata = metadata
      @files = Array.new
      @manifest = Mash.new(
        recipes: Array.new,
        definitions: Array.new,
        libraries: Array.new,
        attributes: Array.new,
        files: Array.new,
        templates: Array.new,
        resources: Array.new,
        providers: Array.new,
        root_files: Array.new
      )

      load_files
    end

    # @return [String]
    #   the name of the cookbook and the version number separated by a dash (-).
    #
    #   example:
    #     "nginx-0.101.2"
    def name
      "#{cookbook_name}-#{version}"
    end

    # @return [Hash]
    def dependencies
      metadata.recommendations.merge(metadata.dependencies)
    end

    # @return [Hash]
    #   an hash containing the checksums and expanded file paths of all of the
    #   files found in the instance of CachedCookbook
    #
    #   example:
    #     {
    #       "da97c94bb6acb2b7900cbf951654fea3" => "/Users/reset/.berkshelf/nginx-0.101.2/README.md"
    #     }
    def checksums
      {}.tap do |checksums|
        files.each do |file|
          checksums[self.class.checksum(file)] = file
        end
      end
    end

    # @param [Symbol] category
    #   the category of file to generate metadata about
    # @param [String] target
    #   the filepath to the file to get metadata information about
    #
    # @return [Hash]
    #   a Hash containing a name, path, checksum, and specificity key representing the
    #   metadata about a file contained in a Cookbook. This metadata is used when
    #   uploading a Cookbook's files to a Chef Server.
    #
    #   example:
    #     {
    #       name: "default.rb",
    #       path: "recipes/default.rb",
    #       checksum: "fb1f925dcd5fc4ebf682c4442a21c619",
    #       specificity: "default"
    #     }
    def file_metadata(category, target)
      target = Pathname.new(target)

      {
        name: target.basename.to_s,
        path: target.relative_path_from(path).to_s,
        checksum: self.class.checksum(target),
        specificity: file_specificity(category, target)
      }
    end

    # Validates that this instance of CachedCookbook points to a valid location on disk that
    # contains a cookbook which passes a Ruby and template syntax check. Raises an error if
    # these assertions are not true.
    #
    # @return [Boolean]
    #   returns true if Cookbook is valid
    def validate!
      raise CookbookNotFound, "No Cookbook found at: #{path}" unless path.exist?

      unless quietly { syntax_checker.validate_ruby_files }
        raise CookbookSyntaxError, "Invalid ruby files in cookbook: #{name} (#{version})."
      end
      unless quietly { syntax_checker.validate_templates }
        raise CookbookSyntaxError, "Invalid template files in cookbook: #{name} (#{version})."
      end

      true
    end

    def to_hash
      result = manifest.dup
      result['chef_type'] = 'cookbook_version'
      result['name'] = name
      result['cookbook_name'] = cookbook_name
      result['version'] = version
      result['metadata'] = metadata
      result.to_hash
    end

    def to_json(*a)
      result = self.to_hash
      result['json_class'] = chef_json_class
      result['frozen?'] = false
      result.to_json(*a)
    end

    def to_s
      "#{cookbook_name} (#{version}) '#{path}'"
    end

    def <=>(other_cookbook)
      [self.cookbook_name, self.version] <=> [other_cookbook.cookbook_name, other_cookbook.version]
    end

    private

      attr_reader :files

      def chef_type
        CHEF_TYPE
      end

      def chef_json_class
        CHEF_JSON_CLASS
      end

      def syntax_checker
        @syntax_checker ||= Chef::Cookbook::SyntaxCheck.new(path.to_s)
      end

      def load_files
        load_shallow(:recipes, 'recipes', '*.rb')
        load_shallow(:definitions, 'definitions', '*.rb')
        load_shallow(:attributes, 'attributes', '*.rb')
        load_recursively(:libraries, 'libraries', '*')
        load_recursively(:files, "files", "*")
        load_recursively(:templates, "templates", "*")
        load_recursively(:resources, "resources", "*.rb")
        load_recursively(:providers, "providers", "*.rb")
        load_root
      end

      def load_root
        [].tap do |files|
          Dir.glob(path.join('*'), File::FNM_DOTMATCH).each do |file|
            next if File.directory?(file)
            @files << file
            @manifest[:root_files] << file_metadata(:root_files, file)
          end
        end
      end

      def load_recursively(category, category_dir, glob)
        [].tap do |files|
          file_spec = path.join(category_dir, '**', glob)
          Dir.glob(file_spec, File::FNM_DOTMATCH).each do |file|
            next if File.directory?(file)
            @files << file
            @manifest[category] << file_metadata(category, file)
          end
        end
      end

      def load_shallow(category, *path_glob)
        [].tap do |files|
          Dir[path.join(*path_glob)].each do |file|
            @files << file
            @manifest[category] << file_metadata(category, file)
          end
        end
      end

      # @param [Symbol] category
      # @param [Pathname] target
      #
      # @return [String]
      def file_specificity(category, target)
        case category
        when :files, :templates
          relpath = target.relative_path_from(path).to_s
          relpath.slice(/(.+)\/(.+)\/.+/, 2)
        else
          'default'
        end
      end
  end
end
