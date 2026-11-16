require "logger"
require "active_support/core_ext/class"
require "active_support/core_ext/module"
require "active_support/concern"
require "spiderman/version"
require "spiderman/acts_as_nokogiri_document"
require "spiderman/runner"
require "spiderman/run"
require 'spiderman/railtie' if defined?(Rails)

# Turn any class into a crawler by including this module.
#
# Example:
#
#   class MySpider < ApplicationJob # Yup, you can define this in a job
#     queue_as :crawler
#
#     include Spiderman
#
#     crawl "https://example.com/" do |response|
#       response.css('.selector a').each do |a|
#         process! a["href"], :listing
#       end
#     end
#
#     process :listing do |response|
#       process! response.css('img'), :image
#       save_the_thing response.css('.some_selector')
#     end
#
#     process :image do |response|
#       # Do something with the image file
#     end
#
#     def save_the_thing(thing)
#       # logic here for saving the thing
#     end
#  end
#
module Spiderman
  extend ActiveSupport::Concern

  included do
    Spiderman.add(self)
    class_attribute :crawler, instance_reader: true, default: Runner.new
    class_attribute :current_run, instance_reader: true, default: nil

    delegate :logger, to: :crawler unless method_defined?(:logger)
  end

  class_methods do
    delegate :crawl!, :process!, to: :new

    # Use `crawl` to specify URLs to start with. `crawl` accepts one or more
    # URLs, and will call the block for each URL requested. You can also
    # define multiple `crawl` blocks with different behavior for each
    # starting URL. All `crawl` blocks will be called when calling
    # `SpiderName.crawl!`.
    #
    # `response` is a `Net::HTTPResponse` object that also acts like a
    # `Nokogiri::HTML` document, e.g. `response.css(…)`
    def crawl(*urls, &block)
      urls.each { |url| crawler.register(url, &block) }
      crawler.start_at(*urls)
    end

    # Processors are called from `crawl` and can be used to handle different
    # types of responses.
    def process(type, &block)
      crawler.register(type, &block)
    end

    def inherited(subclass)
      super
      subclass.crawler = crawler.dup
      subclass.current_run = nil
      Spiderman.add(subclass)
    end
  end

  # Begin a crawl, or resume one that was interrupted.
  #
  # The first call snapshots the crawler's urls, handlers and headers into
  # a `Run`, so changes to the class afterwards do not affect the run in
  # flight. Every requested URL is recorded with its parent URL, depth and
  # status. Later calls resume the same run and only dispatch steps that
  # have not succeeded yet — successful pages are never requested twice.
  #
  # Returns the `Run`, whose `steps` can be inspected to locate failures.
  def crawl!
    run = self.class.current_run || (self.class.current_run = Run.new(crawler))
    run.schedule_seeds!

    if active_job?
      run.incomplete_steps.each { |step| self.class.perform_later(step.url.to_s, step.with) }
    else
      run.resume(self)
    end

    run
  end

  def process!(url, with = nil)
    run = self.class.current_run
    return if run && !run.schedule(url, with)

    if active_job?
      self.class.perform_later(url.to_s, with)
    elsif run
      run.resume(self)
    else
      perform(url, with)
    end
  end

  def perform(url, with = nil)
    if (run = self.class.current_run)
      step = run.step_for(url) || run.schedule(url, with)
      run.perform_step(self, step) if step
    else
      handler = crawler.handler_for(with || url)
      response = crawler.request(url)
      instance_exec response, &handler
    end
  end

  def name
    self.class.name.demodulize
  end

  private

  def active_job?
    defined?(ActiveJob::Base) && self.is_a?(ActiveJob::Base)
  end

  module_function

  def list
    @list ||= []
  end

  def run(crawler = nil)
    crawlers = crawler ? [find(crawler)] : list
    crawlers.each(&:crawl!)
  end

  def find(name)
    self.list.detect { |crawler| crawler.name.demodulize.underscore == name }
  end

  def add(clazz)
    list.push(clazz)
  end
end
