RSpec.describe Spiderman::Run do
  before do
    Spiderman::Runner.logger = Logger.new(STDOUT, level: :unknown)
  end

  def build_spider(&block)
    Class.new { include Spiderman }.tap do |klass|
      klass.class_exec(&block) if block
    end
  end

  def html_with_links(*hrefs)
    links = hrefs.map { |href| %(<a href="#{href}">x</a>) }.join
    "<html><body>#{links}</body></html>"
  end

  describe "step ledger" do
    it "records parent URL, depth and status for every request" do
      stub_request(:get, "https://example.com/start")
      stub_request(:get, "https://example.com/child")

      spider = build_spider do
        crawl "https://example.com/start" do |_res|
          process! "https://example.com/child", :item
        end
        process(:item) { |_res| }
      end

      run = spider.new.crawl!

      seed, child = run.steps
      expect(seed.status).to eq(:success)
      expect(seed.url).to eq("https://example.com/start")
      expect(seed.parent_url).to be_nil
      expect(seed.depth).to eq(0)

      expect(child.status).to eq(:success)
      expect(child.url).to eq("https://example.com/child")
      expect(child.parent_url).to eq("https://example.com/start")
      expect(child.depth).to eq(1)
      expect(run).to be_complete
    end
  end

  describe "interruption and resume" do
    it "records the failure with its error and only redispatches incomplete steps" do
      ok = stub_request(:get, "https://example.com/ok")
      broken = stub_request(:get, "https://example.com/broken")

      failing = true
      spider = build_spider do
        crawl "https://example.com/ok" do |_res|
          process! "https://example.com/broken", :page
        end
        process(:page) do |_res|
          raise "boom" if failing
        end
      end

      expect { spider.new.crawl! }.to raise_error("boom")

      run = spider.current_run
      expect(run).not_to be_complete
      expect(run.failed_steps.size).to eq(1)

      failed = run.failed_steps.first
      expect(failed.url).to eq("https://example.com/broken")
      expect(failed.parent_url).to eq("https://example.com/ok")
      expect(failed.depth).to eq(1)
      expect(failed.error).to be_a(RuntimeError)
      expect(failed.error.message).to eq("boom")

      # Resume: the failed step is retried, the successful one is not
      failing = false
      expect { spider.new.crawl! }.not_to raise_error

      expect(run).to be_complete
      expect(ok).to have_been_made.once
      expect(broken).to have_been_made.twice
    end

    it "does not disguise an exception as completion" do
      stub_request(:get, "https://example.com/")
      spider = build_spider do
        crawl("https://example.com/") { |_res| raise "nope" }
      end

      expect { spider.new.crawl! }.to raise_error("nope")
      step = spider.current_run.steps.first
      expect(step.status).to eq(:failed)
      expect(step.status).not_to eq(:success)
      expect(spider.current_run).not_to be_complete
    end
  end

  describe "rerun" do
    it "does not request anything once every step has succeeded" do
      request = stub_request(:get, "https://example.com/")
      spider = build_spider do
        crawl("https://example.com/") { |_res| }
      end

      spider.new.crawl!
      spider.new.crawl!
      spider.crawl!

      expect(request).to have_been_made.once
    end
  end

  describe "cycles" do
    it "delivers each URL at most once and records the duplicate as cancelled" do
      a = stub_request(:get, "https://example.com/a")
                .to_return(body: html_with_links("https://example.com/b"))
      b = stub_request(:get, "https://example.com/b")
                .to_return(body: html_with_links("https://example.com/a"))

      spider = build_spider do
        crawl "https://example.com/a" do |res|
          res.css("a").each { |link| process! link["href"] }
        end
        process "https://example.com/b" do |res|
          res.css("a").each { |link| process! link["href"] }
        end
      end

      run = spider.new.crawl!

      expect(a).to have_been_made.once
      expect(b).to have_been_made.once
      expect(run).to be_complete

      cancelled = run.cancelled_steps
      expect(cancelled.size).to eq(1)
      expect(cancelled.first.url).to eq("https://example.com/a")
      expect(cancelled.first.parent_url).to eq("https://example.com/b")
      expect(cancelled.first.depth).to eq(2)
    end
  end

  describe "URL normalization" do
    it "delivers equivalent URLs at most once per run" do
      page = stub_request(:get, "https://example.com/page")
      stub_request(:get, "https://example.com/start")
        .to_return(body: html_with_links(
          "https://example.com/page",
          "https://EXAMPLE.COM/page#section"
        ))

      spider = build_spider do
        crawl "https://example.com/start" do |res|
          res.css("a").each { |link| process! link["href"] }
        end
        process "https://example.com/page" do |_res| end
      end

      run = spider.new.crawl!

      expect(page).to have_been_made.once
      expect(run.successful_steps.map(&:url))
        .to contain_exactly("https://example.com/start", "https://example.com/page")
      expect(run.cancelled_steps.size).to eq(1)
      expect(run.cancelled_steps.first.url).to eq("https://EXAMPLE.COM/page#section")
    end
  end

  describe "run snapshot" do
    it "freezes urls, handlers and headers when the run starts" do
      page = stub_request(:get, "https://example.com/page")
      stub_request(:get, "https://example.com/start")
      added = stub_request(:get, "https://example.com/added")

      failing = true
      spider = build_spider do
        crawl "https://example.com/start" do |_res|
          process! "https://example.com/page", :page
        end
        process(:page) do |_res|
          raise "boom" if failing
        end
      end
      spider.crawler.headers[:x_run] = "one"

      expect { spider.new.crawl! }.to raise_error("boom")

      # Mutate the class while the run is in flight
      spider.crawler.headers[:x_run] = "two"
      spider.process(:page) { |_res| raise "new handler must not run" }
      spider.crawl("https://example.com/added") { |_res| }

      failing = false
      expect { spider.new.crawl! }.not_to raise_error

      # URLs snapshot: the newly added seed is not crawled by this run
      expect(added).not_to have_been_requested
      # Headers snapshot: the retry still uses the headers from run start
      expect(page.with(headers: { "X-Run" => "one" })).to have_been_requested.twice
      expect(page.with(headers: { "X-Run" => "two" })).not_to have_been_requested
      # Handler snapshot: the old handler ran, so the run completed
      expect(spider.current_run).to be_complete
    end
  end

  describe "inheritance" do
    it "gives each subclass its own run built from its inherited snapshot" do
      stub_request(:get, "https://example.com/base")
      stub_request(:get, "https://example.com/child")

      parent = build_spider do
        crawl("https://example.com/base") { |_res| }
      end
      child = Class.new(parent) do
        crawl("https://example.com/child") { |_res| }
      end

      child_run = child.new.crawl!
      expect(child_run.successful_steps.map(&:url))
        .to contain_exactly("https://example.com/base", "https://example.com/child")

      # The parent was not affected by the child's run
      expect(parent.current_run).to be_nil

      parent_run = parent.new.crawl!
      expect(parent_run.successful_steps.map(&:url))
        .to contain_exactly("https://example.com/base")
    end
  end
end
