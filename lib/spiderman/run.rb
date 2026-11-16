require "uri"

module Spiderman
  # A single crawl run.
  #
  # A Run is created when `crawl!` is first called and snapshots the
  # crawler's urls, handlers and headers, so changing the class (e.g.
  # re-registering `crawl`/`process` blocks or headers on a parent class)
  # while a run is in flight does not affect that run.
  #
  # Every requested URL is recorded as a Step with its parent URL, depth
  # and status (:pending, :running, :success, :failed, :cancelled), so a
  # failed page can be located and an interrupted run can be resumed:
  # only steps that have not succeeded are dispatched again. Within a
  # run, each normalized URL is successfully delivered at most once.
  class Run
    # One requested URL within a run.
    class Step
      attr_reader :url, :with, :parent_url, :depth, :error, :status

      def initialize(url, with, parent_url, depth)
        @url = url
        @with = with
        @parent_url = parent_url
        @depth = depth
        @status = :pending
        @error = nil
      end

      def start!
        @status = :running
      end

      def succeed!
        @status = :success
      end

      def fail!(error)
        @status = :failed
        @error = error
      end

      def cancel!
        @status = :cancelled
      end

      def success?
        @status == :success
      end

      def failed?
        @status == :failed
      end

      def cancelled?
        @status == :cancelled
      end

      # Nothing more to do: already delivered, or deliberately skipped.
      def complete?
        success? || cancelled?
      end

      # Needs (re)dispatching: never attempted, or attempted but failed.
      def dispatchable?
        @status == :pending || @status == :failed
      end
    end

    attr_reader :crawler, :steps, :current_step

    def initialize(crawler)
      # Snapshot the configuration for this run
      @crawler = crawler.dup
      @steps = []
      @steps_by_url = {}
      @current_step = nil
      @draining = false
    end

    # Normalize a URL so that equivalent URLs (case, default ports,
    # fragments) are only delivered once per run.
    def self.normalize(url)
      uri = URI.parse(url.to_s.strip)
      uri.fragment = nil
      uri.normalize.to_s
    rescue URI::InvalidURIError
      url.to_s
    end

    # Enqueue the seed URLs captured in the snapshot. Idempotent: seeds
    # that are already known are left untouched so resuming a run does
    # not reset or duplicate them.
    def schedule_seeds!
      crawler.urls.each { |url| schedule(url, nil, parent: nil, record_duplicate: false) }
    end

    # Schedule a URL discovered while crawling. Returns the step to
    # dispatch, or nil when the normalized URL is already delivered or
    # in flight. A failed step is returned again so it can be retried.
    # Duplicates are recorded as cancelled steps (with their
    # parent and depth) so the link graph stays inspectable.
    def schedule(url, with = nil, parent: current_step, record_duplicate: true)
      key = self.class.normalize(url)
      depth = parent ? parent.depth + 1 : 0
      parent_url = parent && parent.url

      if (existing = @steps_by_url[key])
        return existing if existing.failed?

        if record_duplicate
          duplicate = Step.new(url, with, parent_url, depth)
          duplicate.cancel!
          @steps << duplicate
        end
        return nil
      end

      step = Step.new(url, with, parent_url, depth)
      @steps << step
      @steps_by_url[key] = step
      step
    end

    def step_for(url)
      @steps_by_url[self.class.normalize(url)]
    end

    # Steps that still need to be (re)dispatched: pending or failed.
    def incomplete_steps
      @steps.select(&:dispatchable?)
    end

    def failed_steps
      @steps.select(&:failed?)
    end

    def successful_steps
      @steps.select(&:success?)
    end

    def cancelled_steps
      @steps.select(&:cancelled?)
    end

    def complete?
      incomplete_steps.empty?
    end

    # Synchronously perform every incomplete step, in the order they
    # were scheduled. Steps scheduled by handlers while draining are
    # picked up as the loop advances. An exception marks the step as
    # failed and propagates, aborting the run so it can be resumed
    # later. Re-entrant calls (from `process!` inside a handler) return
    # immediately and let the outer loop continue.
    def resume(context)
      return if @draining

      @draining = true
      begin
        while (step = @steps.find(&:dispatchable?))
          perform_step(context, step)
        end
      ensure
        @draining = false
      end
    end

    # Perform a single step: request the URL with the snapshotted
    # headers and run the snapshotted handler. A step that has already
    # succeeded is never delivered twice. Any exception is recorded on
    # the step and re-raised — a failure is never reported as success.
    def perform_step(context, step)
      return if step.complete?

      step.start!
      previous = @current_step
      @current_step = step
      begin
        handler = crawler.handler_for(step.with || step.url)
        response = crawler.request(step.url)
        context.instance_exec(response, &handler)
        step.succeed!
      rescue Exception => error # rubocop:disable Lint/RescueException
        step.fail!(error)
        log_failure(step)
        raise
      ensure
        @current_step = previous
      end
    end

    private

    def log_failure(step)
      logger = crawler.logger
      return unless logger

      logger.error(
        "Crawl step failed: #{step.url} " \
        "(parent: #{step.parent_url || '—'}, depth: #{step.depth}): " \
        "#{step.error.class}: #{step.error.message}"
      )
    end
  end
end
