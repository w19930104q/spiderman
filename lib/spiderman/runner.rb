require "net/http"
require "uri"

module Spiderman
  class Runner
    class_attribute :logger, instance_accessor: true, default: Logger.new(STDOUT, level: :info)
    attr_reader :urls, :headers

    def initialize
      @urls = []
      @handlers = {}
      @headers = {}
    end

    def start_at(*urls)
      @urls.append(*urls)
    end

    def register(name, &handler)
      @handlers[name] = handler
    end

    def handler_for(name)
      @handlers[name]
    end

    # Request a URL with the configured headers, following redirects,
    # and return a `Net::HTTPResponse` that acts like a Nokogiri
    # document, e.g. `response.css(…)`.
    def request(url, redirects_remaining = 5)
      uri = URI.parse(url.to_s)
      response = fetch(uri)

      if response.is_a?(Net::HTTPRedirection) && response["location"] && redirects_remaining > 0
        request(URI.join(uri.to_s, response["location"]).to_s, redirects_remaining - 1)
      else
        response.extend ActsAsNokogiriDocument
        response
      end
    end

    def dup
      self.class.new.tap do |obj|
        obj.urls.replace(urls)
        obj.handlers.update(handlers)
        obj.headers.update(headers)
        obj.logger = logger
      end
    end

  protected

    # Allow access for dup
    attr_reader :handlers

  private

    def fetch(uri)
      logger.info("GET #{uri}") if logger
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(build_request(uri))
      end
    end

    def build_request(uri)
      Net::HTTP::Get.new(uri).tap do |request|
        headers.each { |name, value| request[header_name(name)] = value }
      end
    end

    # :user_agent => "User-Agent"
    def header_name(name)
      name.to_s.split("_").map(&:capitalize).join("-")
    end
  end
end
