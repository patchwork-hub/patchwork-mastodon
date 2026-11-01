# lib/tasks/rebuild_feeds.rake
namespace :mastodon do
  desc 'Clear and rebuild all home and list feeds (production)'
  task rebuild_feeds: :environment do
    puts 'Clearing Redis feed keys...'
    redis = Redis.new(url: ENV['REDIS_URL'] || 'redis://localhost:6379/0')
    # Remove all feed keys (home and list)
    redis.scan_each(match: 'feed:*').each_slice(1000) do |keys|
      redis.del(*keys)
    end
    puts 'Feeds cleared.'

    puts 'Rebuilding feeds for all active local accounts...'
    batch = []
    Account.where(is_local: true, suspended: false).find_each(batch_size: 1000) do |account|
      batch << account.id
      if batch.size >= 1000
        system({ 'RAILS_ENV' => 'production' }, "bundle exec rails mastodon:feeds build --account_ids=#{batch.join(',')}")
        batch.clear
      end
    end
    # Process any remaining accounts
    unless batch.empty?
      system({ 'RAILS_ENV' => 'production' }, "bundle exec rails mastodon:feeds build --account_ids=#{batch.join(',')}")
    end
    puts 'Feed rebuild complete.'
  end
end
