# frozen_string_literal: true

module Sequel
  module Notion
    module Schema
      NOTION_TO_SEQUEL = {
        "title"            => { type: :string  },
        "rich_text"        => { type: :string  },
        "number"           => { type: :float   },
        "select"           => { type: :string  },
        "multi_select"     => { type: :array   },
        "status"           => { type: :string  },
        "date"             => { type: :date    },
        "checkbox"         => { type: :boolean },
        "url"              => { type: :string  },
        "email"            => { type: :string  },
        "phone_number"     => { type: :string  },
        "people"           => { type: :array   },
        "relation"         => { type: :array   },
        "formula"          => { type: :string  },
        "created_time"     => { type: :datetime },
        "last_edited_time" => { type: :datetime },
      }.freeze

      module_function

      def notion_to_sequel(properties)
        properties.map do |name, prop|
          notion_type = prop["type"]
          col_info    = (NOTION_TO_SEQUEL[notion_type] || { type: :string })
                          .merge(notion_type: notion_type)

          [name.to_sym, col_info]
        end
      end
    end
  end
end
