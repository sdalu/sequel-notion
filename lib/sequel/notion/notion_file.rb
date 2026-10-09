# frozen_string_literal: true

require "uri"

module Sequel
    module Notion
        # File's "Notion API → File instances" class methods, split out
        # here (and mixed in with `extend`) to keep File's own body
        # under the class-length limit.
        module FileDeserialization
            # Parse a single file object from Notion API response
            #
            #   File.from_notion({
            #     "type" => "external",
            #     "name" => "doc.pdf",
            #     "external" => { "url" => "https://..." }
            #   })
            #
            def from_notion(file_obj)
                return nil unless file_obj.is_a?(Hash)

                case file_obj["type"]
                when "file"     then from_notion_file(file_obj)
                when "external" then from_notion_external(file_obj)
                when nil then raise Sequel::Error, "file object with no type"
                else from_notion_other(file_obj)
                end
            end

            # Parse the "files" property value → array of File
            #
            #   File.from_notion_property(prop)
            #   # => [#<File name="doc.pdf" url="https://...">, ...]
            #
            def from_notion_property(prop)
                files = prop["files"] || []
                files.filter_map { |f| from_notion(f) }
            end

            private

            def extract_caption(file_obj)
                file_obj["caption"]&.map { |t| t["plain_text"] }&.join
            end

            # from_notion's three branches, split out to keep from_notion
            # itself short.

            def from_notion_file(file_obj)
                new(
                    name: file_obj["name"],
                    url: file_obj.dig("file", "url"),
                    type: :file,
                    expiry_time: file_obj.dig("file", "expiry_time"),
                    caption: extract_caption(file_obj)
                )
            end

            def from_notion_external(file_obj)
                new(
                    name: file_obj["name"],
                    url: file_obj.dig("external", "url"),
                    type: :external,
                    caption: extract_caption(file_obj)
                )
            end

            # A type this adapter does not know yet (Notion added one
            # after this was written): round-trip it opaquely via @raw
            def from_notion_other(file_obj)
                type = file_obj["type"]
                new(
                    name: file_obj["name"],
                    url: file_obj.dig(type, "url"),
                    type: type,
                    caption: extract_caption(file_obj),
                    raw: file_obj
                )
            end
        end

        class File
            extend FileDeserialization

            attr_reader :name, :url, :expiry_time, :type, :caption, :raw

            # Keywords besides url:, name: and type:
            OPTIONS = %i[expiry_time caption raw].freeze

            # type: :file (Notion-hosted) or :external; any other is kept
            # with its raw hash, so that it is written back unchanged
            def initialize(url:, name: nil, type: :external, **opts)
                unknown = opts.keys - OPTIONS
                unless unknown.empty?
                    raise ArgumentError, "unknown keywords: #{unknown.inspect}"
                end

                @name        = name
                @url         = url
                @type        = type.to_sym
                @expiry_time = opts[:expiry_time]
                @caption     = opts[:caption]
                @raw         = opts[:raw]
            end

            # Is this a Notion-hosted (internal) file?
            def internal? = @type == :file

            # Is this an external URL?
            def external? = @type == :external

            # Has the Notion-hosted URL expired?
            def expired?
                return false unless internal? && @expiry_time

                Time.parse(@expiry_time) < Time.now
            end

            # ----------------------------------------------------------
            # Serialisation: File → Notion API property value
            # ----------------------------------------------------------

            # Single file → Notion file object (for use inside arrays)
            def to_notion
                case @type
                when :external then to_notion_external
                when :file then to_notion_file
                else @raw
                end
            end

            # Build Notion "files" property value from one or more Files
            #
            #   File.to_notion_property([file1, file2])
            #   # => { "files" => [ { ... }, { ... } ] }
            #
            def self.to_notion_property(files)
                files = Array(files)
                { "files" => files.map(&:to_notion) }
            end

            # ----------------------------------------------------------
            # Convenience constructors
            # ----------------------------------------------------------

            # Create an external file reference
            #
            #   File.external("https://example.com/doc.pdf", name: "My Doc")
            #
            def self.external(url, name: nil)
                new(url: url, type: :external, name: name)
            end

            # Wrap multiple URLs into File instances
            #
            #   File.from_urls("https://a.com/1.pdf", "https://b.com/2.pdf")
            #
            def self.from_urls(*urls)
                urls.flatten.map { |u| external(u) }
            end

            # ----------------------------------------------------------
            # Comparison & display
            # ----------------------------------------------------------

            # raw tells apart files of an unknown type, which may have no URL
            def ==(other)
                other.is_a?(File) && @url == other.url &&
                    @type == other.type && @raw == other.raw
            end
            alias eql? ==

            def hash
                [@url, @type, @raw].hash
            end

            def to_s
                tag = expired? ? " [EXPIRED]" : ""
                "#<#{self.class}:#{@type} #{@name || "unnamed"} → " \
                    "#{@url}#{tag}>"
            end
            alias inspect to_s

            private

            # to_notion's two branches, split out to keep to_notion itself
            # short.

            def to_notion_external
                uri = parsed_url
                { "type" => "external", "name" => @name || default_name(uri),
                  "external" => { "url" => @url } }
            end

            def parsed_url
                URI.parse(@url)
            rescue URI::InvalidURIError
                raise Sequel::Error, "invalid file URL: #{@url.inspect}"
            end

            # The URL's last path segment, decoded ("a%20b.pdf" is
            # "a b.pdf"; one that does not decode stays as it is), or the
            # URL when it has none
            def default_name(uri)
                base = ::File.basename(uri.path.to_s)
                return @url if ["", "/"].include?(base)

                name = URI.decode_uri_component(base)
                name.valid_encoding? ? name : base
            rescue ArgumentError
                base
            end

            def to_notion_file
                # Notion-hosted files are read-only via the API;
                # you can reference them but not upload new ones this way.
                # Return the existing structure for round-tripping.
                obj = {
                    "type" => "file",
                    "name" => @name || "",
                    "file" => { "url" => @url }
                }
                obj["file"]["expiry_time"] = @expiry_time if @expiry_time
                obj
            end
        end
    end
end
