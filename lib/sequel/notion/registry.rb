# frozen_string_literal: true

require "sequel/notion/discovery"

module Sequel
    module Notion
        # Table name => data source id, filled explicitly, by discovery, or
        # lazily by searching for a data source of that name.
        module Registry
            include Discovery

            UUID = /\A\h{8}-?\h{4}-?\h{4}-?\h{4}-?\h{12}\z/

            # A discovered name that several data sources share: looking
            # it up raises, until a registration picks one
            Ambiguous = Data.define(:ids)

            # The table name a data source title maps to: accents dropped
            # from Latin letters only, letters of other scripts kept
            def self.normalize(title)
                title.to_s.unicode_normalize(:nfkd)
                     .gsub(/(?<=\p{Latin})\p{Mn}+/, "")
                     .unicode_normalize(:nfc)
                     .downcase
                     .gsub(/[^\p{L}\p{N}]+/, "_")
                     .gsub(/\A_|_\z/, "")
            end

            def register_data_source(name, data_source_id)
                raise Error, "Missing data source id for #{name}" unless
                    data_source_id

                registry_store(name.to_sym, data_source_id.to_s)
                self
            end

            # Register every data source found (in one database, or by a
            # search); the block, given (title, id), may choose the name.
            # All or nothing: a name clash registers none of them.
            def register_all_data_sources(database: nil, query: nil, &mapper)
                found = live(data_sources(database:, query:)).map do |ds|
                    [source_name(ds, mapper), ds[:id]]
                end
                Sequel.synchronize do
                    staged = registry.dup
                    found.each { |name, id| bind(staged, name, id) }
                    registry.replace(staged)
                end
                self
            end

            def data_source_id_for(table_name)
                name = table_name.to_sym
                resolved(name, registry_fetch(name)) ||
                    (name.match?(UUID) && name.to_s.downcase) ||
                    (auto_register? && resolved(name, registry_fetch(name))) ||
                    search_data_source(name)
            end

            def tables
                auto_register?
                Sequel.synchronize do
                    registry.reject { |_, id| id.is_a?(Ambiguous) }.keys
                end
            end

            private

            def registry = (@registry ||= {})

            # A title with no letter or digit is named by its id
            def source_name(source, mapper)
                return mapper.call(source[:name], source[:id]).to_sym if mapper

                name = Registry.normalize(source[:name])
                (name.empty? ? source[:id] : name).to_sym
            end

            def registry_fetch(name) = Sequel.synchronize { registry[name] }

            def registry_store(name, id)
                Sequel.synchronize { bind(registry, name, id) }
            end

            def resolved(name, id)
                return id unless id.is_a?(Ambiguous)

                raise Error, "data source name #{name} is ambiguous " \
                             "(#{id.ids.join(", ")}): register one"
            end

            # A registration may resolve an ambiguous name, never rebind
            # one already bound
            def bind(map, name, id)
                old = map[name]
                if old && old != id && !old.is_a?(Ambiguous)
                    raise Error, "data source name #{name} already maps " \
                                 "to #{old}, not #{id}"
                end
                map[name] = id
            end

            # Discover every data source once, when auto_register is set;
            # true when it is set. A name two sources share is marked
            # ambiguous rather than failing the others, and a name already
            # registered is kept. As Sequel does for its schema cache, the
            # flag is set only once discovery has succeeded, and no lock is
            # held across the requests: a concurrent lookup repeats the
            # discovery rather than read a registry half filled, and a
            # failed one is retried on the next lookup.
            def auto_register?
                return false unless opts[:auto_register]

                unless Sequel.synchronize { @auto_registered }
                    discover_data_sources
                    Sequel.synchronize { @auto_registered = true }
                end
                true
            end

            def discover_data_sources
                found = live(data_sources).group_by { source_name(it, nil) }
                Sequel.synchronize do
                    found.each { |name, sources| discovered(name, sources) }
                end
            end

            def discovered(name, sources)
                return if registry[name] in String

                ids = sources.map { it[:id] }.uniq
                registry[name] = ids.one? ? ids.first : Ambiguous[ids]
            end

            # Fallback: search by name, and remember what was found
            def search_data_source(name)
                ids = matching_source_ids(name)
                return if ids.empty?
                if ids.size > 1
                    raise Error, "data source name #{name} is ambiguous: " \
                                 "#{ids.join(", ")}"
                end

                registry_store(name, ids.first)
                ids.first
            end
        end
    end
end
