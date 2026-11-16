require "nokogiri"

module Spiderman
  # Mixed into a `Net::HTTPResponse` to make it act like a Nokogiri
  # document, e.g. `response.css(…)`.
  module ActsAsNokogiriDocument
    def document
      @document ||= Nokogiri::HTML(body.to_s)
    end

    def method_missing(name, *args, &block)
      if document.respond_to?(name)
        document.public_send(name, *args, &block)
      else
        super
      end
    end

    def respond_to_missing?(name, include_private = false)
      document.respond_to?(name) || super
    end
  end
end
