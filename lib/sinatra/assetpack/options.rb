module Sinatra
  module AssetPack
    # Assets.
    #
    # == Common usage
    #
    #     SinatraApp.assets {
    #       # dsl stuff here
    #     }
    #
    #     a = SinatraApp.assets
    #
    # Getting options:
    #
    #     a.js_compression
    #     a.output_path
    #
    # Served:
    #
    #     a.served         # { '/js' => '/var/www/project/app/js', ... }
    #                      # (URL path => local path)
    #
    # Packages:
    #
    #     a.packages       # { 'app.css' => #<Package>, ... }
    #                      # (name.type => package instance)
    #
    # Build:
    #
    #     a.build! { |path| puts "Building #{path}" }
    #
    # Lookup:
    #
    #     a.local_path_for('/images/bg.gif')
    #     a.served?('/images/bg.gif')
    #
    #     a.glob('/js/*.js', '/js/vendor/**/*.js')
    #     # Returns a HashArray of (local => remote)
    #
    class Options
      extend Configurator

      def initialize(app, &blk)
        @app             = app
        @js_compression  = :jsmin
        @css_compression = :simple
        @output_path     = app.public

        @js_compression_options  = Hash.new
        @css_compression_options = Hash.new

        reset!

        # Defaults!
        serve '/css',    :from => 'app/css'
        serve '/js',     :from => 'app/js'
        serve '/images', :from => 'app/images'

        instance_eval &blk  if block_given?
      end

      # =====================================================================
      # DSL methods

      def serve(path, options={})
        raise Error  unless options[:from]
        return  unless File.directory?(File.join(app.root, options[:from]))

        @served[path] = options[:from]
      end

      # Undo defaults.
      def reset!
        @served   = Hash.new
        @packages = Hash.new
      end

      # Adds some JS packages.
      #
      #     js :foo, '/js', [ '/js/vendor/jquery.*.js' ]
      #
      def js(name, path, files=[])
        @packages["#{name}.js"] = Package.new(self, name, :js, path, files)
      end

      # Adds some CSS packages.
      #
      #     css :app, '/css', [ '/css/screen.css' ]
      #
      def css(name, path, files=[])
        @packages["#{name}.css"] = Package.new(self, name, :css, path, files)
      end

      attr_reader   :app        # Sinatra::Base instance
      attr_reader   :packages   # Hash, keys are "foo.js", values are Packages
      attr_reader   :served     # Hash, paths to be served.
                                # Key is URI path, value is local path

      attrib :js_compression    # Symbol, compression method for JS
      attrib :css_compression   # Symbol, compression method for CSS
      attrib :output_path       # '/public'

      attrib :js_compression_options   # Hash
      attrib :css_compression_options  # Hash
      
      # =====================================================================
      # Stuff

      attr_reader :served

      def build!(&blk)
        session = Rack::Test::Session.new app

        packages.each { |_, pack|
          out = session.get(pack.path).body

          write pack.path, out, &blk
          write pack.production_path, out, &blk
        }

        files.each { |path, local|
          out = session.get(path).body
          write path, out, &blk
          write BusterHelpers.add_cache_buster(path, local), out, &blk
        }
      end

      def served?(path)
        !! local_file_for(path)
      end

      # Returns the local file for a given URI path.
      # Returns nil if a file is not found.
      def local_file_for(path)
        path = path.squeeze('/')

        uri, local = served.detect { |uri, local| path[0...uri.size] == uri }

        if local
          path = path[uri.size..-1]
          path = File.join app.root, local, path

          path  if File.exists?(path)
        end
      end

      # Returns the local file for a given URI path. (for dynamic files)
      # Returns nil if a file is not found.
      # TODO: consolidate with local_file_for
      def dyn_local_file_for(file, from)
        # Remove extension
        file = $1  if file =~ /^(.*)(\.[^\.]+)$/

        # Remove cache-buster (/js/app.28389.js => /js/app)
        file = $1  if file =~ /^(.*)\.[0-9]+$/

        Dir[File.join(app.root, from, "#{file}.*")].first
      end

      # Writes `public/#{path}` based on contents of `output`.
      def write(path, output)
        require 'fileutils'

        path = File.join(@output_path, path)
        yield path  if block_given?

        FileUtils.mkdir_p File.dirname(path)
        File.open(path, 'w') { |f| f.write output }
      end

      # Returns the files as a hash.
      def files(match=nil)
          # All
          # A buncha tuples
          tuples = @served.map { |prefix, local_path|
            path = File.expand_path(File.join(@app.root, local_path))
            spec = File.join(path, '**', '*')

            Dir[spec].map { |f|
              [ to_uri(f, prefix, path), f ]
            }
          }.flatten.compact

          Hash[*tuples]
      end

      # Returns an array of URI paths of those matching given globs.
      def glob(*match)
        tuples = match.map { |spec|
          paths = files.keys.select { |f| File.fnmatch?(spec, f) }.sort
          paths.map { |key| [key, files[key]] }
        }

        HashArray[*tuples.flatten]
      end

      def cache
        @cache ||= Hash.new
      end

      def reset_cache
        @cache = nil && cache
      end

    private
      # Returns a URI for a given file
      #     path = '/projects/x/app/css'
      #     to_uri('/projects/x/app/css/file.sass', '/styles', path) => '/styles/file.css'
      #
      def to_uri(f, prefix, path)
        fn = (prefix + f.gsub(path, '')).squeeze('/')

        # Switch the extension ('x.sass' => 'x.css')
        file_ext = File.extname(fn).to_s[1..-1]
        out_ext  = AssetPack.tilt_formats[file_ext]

        fn = fn.gsub(/\.#{file_ext}$/, ".#{out_ext}")  if file_ext && out_ext

        fn
      end
    end
  end
end
