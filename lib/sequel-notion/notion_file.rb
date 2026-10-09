# frozen_string_literal: true

require "uri"

module Sequel
    module Notion
        class File
            attr_reader :name, :url, :expiry_time, :type, :caption

            # type: :file (Notion-hosted) or :external
            def initialize(url:, name: nil, type: :external,
                           expiry_time: nil, caption: nil)
                @name        = name
                @url         = url
                @type        = type.to_sym
                @expiry_time = expiry_time
                @caption     = caption
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
            # Deserialisation: Notion API → File instances
            # ----------------------------------------------------------

            # Parse a single file object from Notion API response
            #
            #   File.from_notion({
            #     "type" => "external",
            #     "name" => "doc.pdf",
            #     "external" => { "url" => "https://..." }
            #   })
            #
            def self.from_notion(file_obj)
                return nil unless file_obj.is_a?(Hash)

                case file_obj["type"]
                when "file"     then from_notion_file(file_obj)
                when "external" then from_notion_external(file_obj)
                else raise Error, "unhandled type"
                end
            end

            # Parse the "files" property value → array of File
            #
            #   File.from_notion_property(prop)
            #   # => [#<File name="doc.pdf" url="https://...">, ...]
            #
            def self.from_notion_property(prop)
                files = prop["files"] || []
                files.filter_map { |f| from_notion(f) }
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

            def ==(other)
                other.is_a?(File) && @url == other.url && @type == other.type
            end
            alias eql? ==

            def hash
                [@url, @type].hash
            end

            def to_s
                tag = expired? ? " [EXPIRED]" : ""
                "#<#{self.class}:#{@type} #{@name || "unnamed"} → " \
                    "#{@url}#{tag}>"
            end
            alias inspect to_s

            private_class_method def self.extract_caption(file_obj)
                file_obj["caption"]&.map { |t| t["plain_text"] }&.join
            end

            # from_notion's two branches, split out to keep from_notion
            # itself short.

            private_class_method def self.from_notion_file(file_obj)
                new(
                    name: file_obj["name"],
                    url: file_obj.dig("file", "url"),
                    type: :file,
                    expiry_time: file_obj.dig("file", "expiry_time"),
                    caption: extract_caption(file_obj)
                )
            end

            private_class_method def self.from_notion_external(file_obj)
                new(
                    name: file_obj["name"],
                    url: file_obj.dig("external", "url"),
                    type: :external,
                    caption: extract_caption(file_obj)
                )
            end

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

            # The URL's last path segment, or the URL when it has none
            def default_name(uri)
                base = ::File.basename(uri.path.to_s)
                ["", "/"].include?(base) ? @url : base
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
