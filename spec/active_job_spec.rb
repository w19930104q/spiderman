require "active_job"

# A minimal ActiveJob queue adapter used to verify how Spiderman
# dispatches and resumes crawls through ActiveJob.
class FakeQueueAdapter
  attr_reader :enqueued

  def initialize
    @enqueued = []
  end

  def enqueue(job)
    @enqueued << job
  end

  def enqueue_at(job, _timestamp)
    enqueue(job)
  end

  def drain
    @enqueued.shift.perform_now until @enqueued.empty?
  end
end

RSpec.describe "Spiderman with ActiveJob" do
  before do
    Spiderman::Runner.logger = Logger.new(STDOUT, level: :unknown)
  end

  let(:adapter) { FakeQueueAdapter.new }

  def job_spider(adapter, &block)
    Class.new(ActiveJob::Base) do
      include Spiderman
      self.queue_adapter = adapter
      class_exec(&block) if block
    end
  end

  def html_with_links(*hrefs)
    links = hrefs.map { |href| %(<a href="#{href}">x</a>) }.join
    "<html><body>#{links}</body></html>"
  end

  it "enqueues seed URLs as jobs and performs them through the adapter" do
    start = stub_request(:get, "https://example.com/start")
                  .to_return(body: html_with_links("https://example.com/item"))
    item = stub_request(:get, "https://example.com/item")

    spider = job_spider(adapter) do
      crawl "https://example.com/start" do |res|
        res.css("a").each { |a| process! a["href"], :item }
      end
      process(:item) { |_res| }
    end

    spider.crawl!
    expect(start).not_to have_been_requested
    expect(adapter.enqueued.size).to eq(1)

    adapter.drain

    expect(start).to have_been_made.once
    expect(item).to have_been_made.once

    run = spider.current_run
    expect(run).to be_complete
    seed, child = run.steps
    expect([seed.status, seed.depth, seed.parent_url]).to eq([:success, 0, nil])
    expect([child.status, child.depth, child.parent_url])
      .to eq([:success, 1, "https://example.com/start"])
  end

  it "resumes an interrupted run by only re-enqueueing incomplete steps" do
    start = stub_request(:get, "https://example.com/start")
                  .to_return(body: html_with_links("https://example.com/item"))
    item = stub_request(:get, "https://example.com/item")

    failing = true
    spider = job_spider(adapter) do
      crawl "https://example.com/start" do |res|
        res.css("a").each { |a| process! a["href"], :item }
      end
      process(:item) do |_res|
        raise "boom" if failing
      end
    end

    spider.crawl!
    expect { adapter.drain }.to raise_error("boom")

    run = spider.current_run
    expect(run.failed_steps.size).to eq(1)
    failed = run.failed_steps.first
    expect(failed.url).to eq("https://example.com/item")
    expect(failed.parent_url).to eq("https://example.com/start")
    expect(failed.error.message).to eq("boom")
    expect(start).to have_been_made.once
    expect(item).to have_been_made.once

    # Resume: only the failed step is dispatched again
    failing = false
    spider.crawl!
    expect(adapter.enqueued.size).to eq(1)
    adapter.drain

    expect(run).to be_complete
    expect(start).to have_been_made.once
    expect(item).to have_been_made.twice
  end

  it "delivers the same normalized URL at most once per run" do
    stub_request(:get, "https://example.com/start")
      .to_return(body: html_with_links(
        "https://example.com/item",
        "https://example.com/item#details"
      ))
    item = stub_request(:get, "https://example.com/item")

    spider = job_spider(adapter) do
      crawl "https://example.com/start" do |res|
        res.css("a").each { |a| process! a["href"], :item }
      end
      process(:item) { |_res| }
    end

    spider.crawl!
    adapter.drain

    expect(item).to have_been_made.once
    expect(spider.current_run.cancelled_steps.size).to eq(1)
  end

  describe "inheritance" do
    it "runs subclasses through ActiveJob with their own run" do
      base = stub_request(:get, "https://example.com/base")
      child_url = stub_request(:get, "https://example.com/child")

      adapter = self.adapter
      parent = job_spider(adapter) do
        crawl("https://example.com/base") { |_res| }
      end
      child = Class.new(parent) do
        crawl("https://example.com/child") { |_res| }
      end

      child.crawl!
      adapter.drain

      expect(base).to have_been_made.once
      expect(child_url).to have_been_made.once
      expect(child.current_run).to be_complete
      expect(parent.current_run).to be_nil
    end
  end
end
