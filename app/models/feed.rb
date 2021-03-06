require "thread/pool"

class Feed < ActiveRecord::Base
  attr_reader :status

  has_many :articles
  has_many :subscriptions
  has_many :users, through: :subscriptions

  validates :url, presence: true
  validates :url, uniqueness: { case_sensitive: false }

  after_create :update_meta, :update_articles

  @@feed_memo = {}

  class << self
    def update_feeds_concurrently(feeds)
      pool = Thread.pool(24)
      feeds.each do |feed|
        pool.process { feed.update_from_remote }
      end
      pool.shutdown

      # SQL UPDATES still need to be handled sequentially
      feeds.map(&:update_articles)
    end

    def top_feeds(limit=10)
      joins(:subscriptions).
        select("feeds.*", "count(subscriptions.*) as sub_count").
        group("feeds.id").
        order("sub_count desc").
        limit(limit)
    end
  end

  def update_meta
    self.update_attributes!(title: feed.title, updated_at: Time.zone.now)
  end

  def update_articles
    feed # check feed status
    return if @status == :bad
    feed.entries.each do |entry|
      article = Article.where(url: entry.url, feed: self).first
      if article.nil?
        Article.create!(title: entry.title,
                        url: entry.url,
                        summary: entry.summary,
                        published_at: entry.published,
                        author: entry.author,
                        body: entry.content,
                        feed: self)
      end
      self.update_attributes!(updated_at: Time.zone.now)
    end
  end

  def update_from_remote
    @feed = remote_feed
  end

  private

  def feed
    if @status == :bad
      @feed = remote_feed
    else
      @feed ||= remote_feed
    end
  end

  def remote_feed
    # Feedjira handles bad responses really poorly (sets return to a
    # Fixnum). If we get a bad response we'll need to ignore the
    # garbage response until we get a good one.
    response = Feedjira::Feed.fetch_and_parse(url)
    if response.is_a?(Fixnum)
      @status = :bad
    else
      @status = :ok
    end
    response
  end
end
