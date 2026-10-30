# frozen_string_literal: true

# The production timestamp_id() function was found to return bare
# epoch-milliseconds (no <<16 shift, no sequence tail), producing ids like
# 1793368877069 instead of proper snowflakes like 117530281753534126.
# Because all timeline/profile ordering and Redis feed scores key off id,
# every status created with the broken function sorts below all prior
# content — making channels and home timelines appear "frozen".
#
# This migration force-recreates the correct function. Mastodon::Snowflake
# .define_timestamp_id is a no-op when the function already exists
# (`already_defined?`), so we must drop it first, then let define_timestamp_id
# recreate it from timestamp_id_sql_string (which has the correct <<16 shift).
class FixTimestampIdFunction < ActiveRecord::Migration[8.1]
  # Columns that use timestamp_id as their id default (from schema.rb).
  TABLES = %w[
    statuses
    accounts
    media_attachments
    notification_requests
    quotes
    collections
    collection_items
  ].freeze

  def up
    safety_assured do
      # The broken function is depended on by column defaults, so it can't be
      # dropped directly. Instead, replace it in place with the correct body.
      # define_timestamp_id is a no-op when the function exists, so we inline
      # the canonical SQL (timestamp_id_sql_string) with CREATE OR REPLACE.
      random_string = SecureRandom.hex(16)
      execute(<<~SQL)
        CREATE OR REPLACE FUNCTION timestamp_id(table_name text)
        RETURNS bigint AS
        $$
          DECLARE
            time_part bigint;
            sequence_base bigint;
            tail bigint;
          BEGIN
            time_part := (
              ((date_part('epoch', now()) * 1000))::bigint
              << 16);

            sequence_base := (
              'x' ||
              substr(
                md5(table_name || '#{random_string}' || time_part::text),
                1, 4
              )
            )::bit(16)::bigint;

            tail := (
              (sequence_base + nextval(table_name || '_id_seq'))
              & 65535);

            RETURN time_part | tail;
          END
        $$ LANGUAGE plpgsql VOLATILE;
      SQL

      # Make sure every table that uses timestamp_id has its sequence.
      Mastodon::Snowflake.ensure_id_sequences_exist

      # Sanity check: a freshly generated id must have the 16-bit shift applied.
      generated = select_value("SELECT timestamp_id('statuses')").to_i
      time_part = generated >> 16
      unless time_part > 1_000_000_000_000 # ~ epoch millis, proves the shift happened
        raise "timestamp_id() still generating unshifted ids: #{generated}"
      end
    end
  end

  def down
    # No-op: we never want to restore the broken function.
  end
end
