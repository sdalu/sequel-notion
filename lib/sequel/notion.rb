# frozen_string_literal: true

# Entry point for `require "sequel/notion"` and Bundler's auto-require;
# Sequel itself loads the adapter on `Sequel.connect(adapter: :notion)`.
require "sequel/adapters/notion"
