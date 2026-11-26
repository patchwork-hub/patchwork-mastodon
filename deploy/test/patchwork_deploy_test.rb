# frozen_string_literal: true

# ruby deploy/test/patchwork_deploy_test.rb
require 'minitest/autorun'
require_relative '../lib/patchwork_deploy'

class PatchworkDeployTest < Minitest::Test
  DEFAULTS = <<~YAML
    provider: ovh
    wave: 2
    tags: []
    image:
      registry: reg.example
      harbor_project: patchwork
      pull_username: robot$patchwork+{project}-{environment}-pull
    host:
      deploy_dir: /srv/mastodon
      credential_dir: /srv/credential
    runtime:
      firebase_container_path: /opt/mastodon/config/firebase-adminsdk.json
    resources:
      web: { cpus: '1', memory: 2G }
  YAML

  def project(wave:, tags: [], staging: 'v4.7.6-pw.1', production: 'v4.7.6-pw.1', production_enabled: true)
    <<~YAML
      wave: #{wave}
      tags: #{tags.inspect}
      environments:
        staging:
          runner: r-staging
          image_tag: #{staging}
        production:
          enabled: #{production_enabled}
          runner: r-production
          image_tag: #{production}
    YAML
  end

  def catalog(**projects)
    PatchworkDeploy::Catalog.new(defaults_text: DEFAULTS, project_texts: projects.transform_keys(&:to_s))
  end

  def base
    catalog(alpha: project(wave: 'canary', tags: ['small']), beta: project(wave: 1), gamma: project(wave: 'last', tags: ['large']))
  end

  def test_config_merges_defaults_project_and_environment
    cfg = base.config('alpha', 'staging')
    assert_equal 'r-staging', cfg['runner']
    assert_equal 'robot$patchwork+alpha-staging-pull', cfg.dig('image', 'pull_username')
    assert_equal '2G', cfg.dig('resources', 'web', 'memory')
  end

  def test_selectors
    assert_equal %w(alpha gamma), base.select('alpha, gamma')
    assert_equal %w(alpha), base.select('wave:canary')
    assert_equal %w(gamma), base.select('tag:large')
    assert_equal %w(beta), base.select('wave=1')
    assert_equal %w(alpha beta gamma), base.select('all')
    assert_raises(PatchworkDeploy::Error) { base.select('nope') }
    assert_raises(PatchworkDeploy::Error) { base.select('') }
  end

  def test_push_deploys_only_changed_environments
    old = base
    new = catalog(alpha: project(wave: 'canary', tags: ['small'], production: 'v4.7.6-pw.2'), beta: project(wave: 1), gamma: project(wave: 'last', tags: ['large']))
    result = PatchworkDeploy::Planner.new(new).plan_push(old)
    assert_empty result.errors
    assert_equal([%w(alpha production v4.7.6-pw.2)], result.deploys.map { |e| e.values_at('project', 'environment', 'image_tag') })
    assert_includes result.deploys.first['release_env'], 'WEB_IMAGE=reg.example/patchwork/web:v4.7.6-pw.2'
  end

  def test_push_without_previous_revision_deploys_nothing
    result = PatchworkDeploy::Planner.new(base).plan_push(nil)
    assert_empty result.deploys
    assert result.notices.any?
  end

  def test_defaults_change_does_not_deploy
    changed_defaults = PatchworkDeploy::Catalog.new(defaults_text: DEFAULTS.sub('memory: 2G', 'memory: 3G'),
                                                    project_texts: { 'alpha' => project(wave: 'canary') })
    old = PatchworkDeploy::Catalog.new(defaults_text: DEFAULTS, project_texts: { 'alpha' => project(wave: 'canary') })
    result = PatchworkDeploy::Planner.new(changed_defaults).plan_push(old)
    assert_empty result.deploys
    assert(result.notices.any? { |n| n.include?('_defaults.yml changed') })
  end

  def test_new_project_is_not_deployed_automatically
    new = catalog(alpha: project(wave: 'canary'), delta: project(wave: 1))
    result = PatchworkDeploy::Planner.new(new).plan_push(catalog(alpha: project(wave: 'canary')))
    assert_empty result.deploys
    assert(result.notices.any? { |n| n.include?('delta is a new project') })
  end

  def test_disabled_environment_is_skipped
    cat = catalog(alpha: project(wave: 1, production_enabled: false))
    result = PatchworkDeploy::Planner.new(cat).plan_dispatch('alpha', 'production')
    assert_empty result.deploys
    assert(result.notices.any? { |n| n.include?('disabled') })
  end

  def test_dispatch_with_tag_override
    result = PatchworkDeploy::Planner.new(base).plan_dispatch('wave:canary,beta', 'staging', 'sha-0123abcd')
    assert_empty result.errors
    assert_equal(%w(alpha beta), result.deploys.map { |e| e.fetch('project') })
    assert(result.deploys.all? { |e| e['image_tag'] == 'sha-0123abcd' })
  end

  def test_production_rejects_sha_builds
    result = PatchworkDeploy::Planner.new(base).plan_dispatch('alpha', 'production', 'sha-0123abcd')
    assert_empty result.deploys
    assert_match(/only accepts release or hotfix/, result.errors.first)
  end

  def test_tag_kinds
    assert_equal :release, PatchworkDeploy.tag_kind('v4.7.6-pw.3')
    assert_equal :hotfix, PatchworkDeploy.tag_kind('v4.7.6-pw.3-newsmast.1')
    assert_equal :sha, PatchworkDeploy.tag_kind('sha-0123abcd')
    assert_nil PatchworkDeploy.tag_kind('latest')
  end
end
