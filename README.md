
<div align="center">
  <h1><img width="300" height="300" src="https://user-images.githubusercontent.com/173/77249168-99488080-6c15-11ea-98de-3d14a412265d.png" alt="Spiderman"></h1>

  <h2>your friendly neighborhood web crawler</h2>
</div>

Spiderman is a Ruby gem for crawling and processing web pages.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'spiderman'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install spiderman

## Usage

```ruby
class HackerNewsCrawler
 include Spiderman

 crawl "https://news.ycombinator.com/" do |response|
   response.css('a.storylink').each do |a|
     process! a["href"], :story
   end
 end

 process :story do |response|
   logging.info "#{response.uri} #{response.css('title').text}"
   save_page(response)
 end

 def save_page(page)
   # logic here for saving the page
 end
end
```

Run the crawler:

```ruby
HackerNewsCrawler.crawl!
```

### Runs, resume and the step ledger

Calling `crawl!` starts a `Spiderman::Run`. The run snapshots the crawler's
URLs, handlers and headers when it starts, so changing the class (or a parent
class) while a crawl is in flight does not affect the run already under way.

Every requested URL is recorded as a step with its parent URL, depth and
status (`:pending`, `:success`, `:failed` or `:cancelled`), which makes it
easy to locate the page that failed:

```ruby
run = HackerNewsCrawler.crawl!
run.failed_steps.each do |step|
  puts "#{step.url} (from #{step.parent_url}, depth #{step.depth}): #{step.error.message}"
end
```

Within a run, each normalized URL is delivered successfully at most once —
links that resolve to an already-handled URL are recorded as `:cancelled`
duplicates, so cycles cannot loop forever. An exception in a handler marks
the step as `:failed` and is re-raised; it is never reported as success.

Calling `crawl!` again resumes the same run and only dispatches steps that
have not succeeded yet — pages that were already crawled are not requested
again.

### ActiveJob

Spiderman works with [ActiveJob](https://edgeguides.rubyonrails.org/active_job_basics.html) out of the box. If your crawler class inherits from `ActiveJob:Base`, then requests will be made in your background worker. Each request will run as a separate job.

```ruby
class MyCrawer < ActiveJob::Base
  queue_as :crawler

  crawl "https://example.com" do |response|
    response.css('a').each {|a| process! a["href"], :link }
  end

  process :link do |response|
    logger.info "Processing #{response.uri}"
  end
end
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/bkeepers/spiderman.


## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
