# frozen_string_literal: true

# Shared logic for the Patchwork release/deploy flow.
#
# A "project" is one Mastodon instance (newsmast, csidnet, ...). It is described
# by deploy/projects/<name>/project.yml, merged on top of
# deploy/projects/_defaults.yml. Each project has one or more environments
# (staging, production) and every environment pins the image tag it runs.
#
# Used by:
#   deploy/bin/plan-deploy  - decides which project/environment pairs to deploy (CI)
#   deploy/bin/rollout      - edits image_tag pins for a selection of projects (humans)
#
# Plain Ruby stdlib only, so it runs on a GitHub-hosted runner without bundler.

require 'yaml'
require 'json'
require 'open3'

module PatchworkDeploy
  ROOT = File.expand_path('../..', __dir__)
  PROJECTS_REL = 'deploy/projects'
  DEFAULTS_FILE = '_defaults.yml'
  PROJECT_FILE = 'project.yml'
  OVERRIDE_FILE = 'compose.override.yml'

  # v4.6.5-pw.3                 normal release, built from a release branch tag
  # v4.6.5-pw.3-newsmast.1      project hotfix on top of a release
  # sha-0123abcd                ad-hoc build from any branch (staging only)
  RELEASE_TAG = /\Av\d+\.\d+\.\d+-pw\.\d+\z/
  HOTFIX_TAG = /\Av\d+\.\d+\.\d+-pw\.\d+-[a-z0-9][a-z0-9-]*\.\d+\z/
  SHA_TAG = /\Asha-[0-9a-f]{7,40}\z/
  PRODUCTION_ENVIRONMENTS = %w(production).freeze
  NAME = /\A[a-z0-9][a-z0-9-]*\z/

  class Error < StandardError; end

  module_function

  def deep_merge(base, other)
    return other unless base.is_a?(Hash) && other.is_a?(Hash)

    base.merge(other) { |_key, a, b| deep_merge(a, b) }
  end

  def parse_yaml(text, label)
    data = YAML.safe_load(text.to_s, permitted_classes: [], aliases: false) || {}
    raise Error, "#{label}: top level must be a mapping" unless data.is_a?(Hash)

    data
  rescue Psych::Exception => e
    raise Error, "#{label}: #{e.message}"
  end

  # Replaces {project} and {environment} in every string of a structure.
  def interpolate(value, vars)
    case value
    when Hash then value.transform_values { |v| interpolate(v, vars) }
    when Array then value.map { |v| interpolate(v, vars) }
    when String then vars.reduce(value) { |s, (k, v)| s.gsub("{#{k}}", v.to_s) }
    else value
    end
  end

  def tag_kind(tag)
    case tag
    when RELEASE_TAG then :release
    when HOTFIX_TAG then :hotfix
    when SHA_TAG then :sha
    end
  end

  # Returns an error string, or nil when the tag may run in that environment.
  def tag_error(tag, environment)
    kind = tag_kind(tag.to_s)
    return "image_tag #{tag.inspect} is not a valid tag (expected v<mastodon>-pw.<n>, v<mastodon>-pw.<n>-<project>.<n> or sha-<commit>)" if kind.nil?
    return "image_tag #{tag} is an ad-hoc sha- build; #{environment} only accepts release or hotfix tags" if kind == :sha && PRODUCTION_ENVIRONMENTS.include?(environment)

    nil
  end

  # All projects, read either from the working tree or from a git revision.
  class Catalog
    attr_reader :defaults, :projects

    # defaults_text: String, project_texts: { name => String }
    def initialize(defaults_text:, project_texts:, overrides: [])
      @defaults = PatchworkDeploy.parse_yaml(defaults_text, "#{PROJECTS_REL}/#{DEFAULTS_FILE}")
      @overrides = overrides
      @projects = project_texts.to_h do |name, text|
        data = PatchworkDeploy.parse_yaml(text, "#{PROJECTS_REL}/#{name}/#{PROJECT_FILE}")
        [name, data]
      end
    end

    def self.from_dir(root = ROOT)
      dir = File.join(root, PROJECTS_REL)
      texts = Dir.glob(File.join(dir, '*', PROJECT_FILE)).sort.to_h do |path|
        [File.basename(File.dirname(path)), File.read(path)]
      end
      overrides = Dir.glob(File.join(dir, '*', OVERRIDE_FILE)).map { |p| File.basename(File.dirname(p)) }
      new(defaults_text: File.read(File.join(dir, DEFAULTS_FILE)), project_texts: texts, overrides: overrides)
    end

    # Returns nil when the revision does not exist (first push of a branch, etc.).
    def self.from_git(rev, root = ROOT)
      return nil if rev.nil? || rev.empty? || rev.match?(/\A0+\z/)

      _, status = Open3.capture2e('git', '-C', root, 'cat-file', '-e', "#{rev}^{commit}")
      return nil unless status.success?

      show = lambda do |path|
        out, st = Open3.capture2e('git', '-C', root, 'show', "#{rev}:#{path}")
        st.success? ? out : nil
      end
      list, = Open3.capture2e('git', '-C', root, 'ls-tree', '--name-only', "#{rev}:#{PROJECTS_REL}")
      texts = {}
      list.split("\n").each do |entry|
        text = show.call("#{PROJECTS_REL}/#{entry}/#{PROJECT_FILE}")
        texts[entry] = text if text
      end
      new(defaults_text: show.call("#{PROJECTS_REL}/#{DEFAULTS_FILE}") || '', project_texts: texts)
    end

    def names
      @projects.keys.sort
    end

    def project?(name)
      @projects.key?(name)
    end

    def environments(name)
      (@projects.fetch(name)['environments'] || {}).keys
    end

    # Only what the project file itself says for this environment (no defaults).
    # Used to detect which environments a commit actually changed.
    def raw_environment(name, environment)
      project = @projects[name] or return nil
      env = (project['environments'] || {})[environment] or return nil
      PatchworkDeploy.deep_merge(project.except('environments'), env)
    end

    # Fully merged configuration: defaults <- project <- project.environments[env]
    def config(name, environment)
      raw = raw_environment(name, environment) or return nil
      merged = PatchworkDeploy.deep_merge(@defaults, raw)
      merged = PatchworkDeploy.interpolate(merged, project: name, environment: environment)
      merged.merge('name' => name, 'environment' => environment,
                   'override_file' => @overrides.include?(name) ? "#{PROJECTS_REL}/#{name}/#{OVERRIDE_FILE}" : '')
    end

    def project_summary(name)
      PatchworkDeploy.deep_merge(@defaults, @projects.fetch(name).except('environments'))
    end

    # selectors: "newsmast,csidnet", "wave:1", "tag:small", "provider=ovh", "all"
    def select(selector_string)
      tokens = selector_string.to_s.split(/[\s,]+/).reject(&:empty?)
      raise Error, 'no projects selected (pass names, wave:<n>, tag:<t>, key=value or all)' if tokens.empty?

      tokens.flat_map { |token| match(token) }.uniq.sort
    end

    private

    def match(token)
      case token
      when 'all'
        names
      when /\Awave:(.+)\z/
        found = names.select { |n| project_summary(n)['wave'].to_s == Regexp.last_match(1) }
        raise Error, "no project has wave #{Regexp.last_match(1)}" if found.empty?

        found
      when /\Atag:(.+)\z/
        found = names.select { |n| Array(project_summary(n)['tags']).map(&:to_s).include?(Regexp.last_match(1)) }
        raise Error, "no project has tag #{Regexp.last_match(1)}" if found.empty?

        found
      when /\A([a-z_]+)=(.+)\z/
        key = Regexp.last_match(1)
        value = Regexp.last_match(2)
        found = names.select { |n| project_summary(n)[key].to_s == value }
        raise Error, "no project has #{key}=#{value}" if found.empty?

        found
      else
        raise Error, "unknown project #{token.inspect} (known: #{names.join(', ')})" unless project?(token)

        [token]
      end
    end
  end

  # Builds the deploy matrix.
  class Planner
    Result = Struct.new(:entries, :notices, :errors, keyword_init: true)

    def initialize(catalog)
      @catalog = catalog
    end

    # A push to deploy/projects/**: deploy every environment whose own settings changed.
    def plan_push(old_catalog)
      notices = []
      pairs = []
      if old_catalog.nil?
        notices << 'No previous revision to compare with (new branch or force push), so nothing is deployed. Use "Run workflow" to deploy explicitly.'
        return finish(pairs, notices)
      end

      if old_catalog.defaults != @catalog.defaults
        affected = @catalog.names.join(', ')
        notices << "_defaults.yml changed. Shared defaults never deploy automatically; affected projects: #{affected}. Roll them out with \"Run workflow\" (e.g. wave by wave)."
      end

      @catalog.names.each do |name|
        unless old_catalog.project?(name)
          notices << "#{name} is a new project. Its first deploy is never automatic; run the workflow for it once the host is ready."
          next
        end
        @catalog.environments(name).each do |env|
          before = old_catalog.raw_environment(name, env)
          after = @catalog.raw_environment(name, env)
          pairs << [name, env, nil] if before != after
        end
      end
      (old_catalog.names - @catalog.names).each { |n| notices << "#{n} was removed from deploy/projects; nothing is torn down automatically." }
      finish(pairs, notices)
    end

    # A manual run: explicit selection, one environment, optional tag override.
    def plan_dispatch(selectors, environment, image_tag_override = nil)
      raise Error, 'environment is required' if environment.to_s.empty?

      notices = []
      pairs = []
      @catalog.select(selectors).each do |name|
        if @catalog.environments(name).include?(environment)
          pairs << [name, environment, image_tag_override.to_s.empty? ? nil : image_tag_override]
        else
          notices << "#{name} has no #{environment} environment; skipped."
        end
      end
      unless image_tag_override.to_s.empty?
        notices << "image_tag #{image_tag_override} was given by hand. Update the pins in deploy/projects with deploy/bin/rollout too, or the next pin change will move these projects back."
      end
      finish(pairs, notices)
    end

    private

    def finish(pairs, notices)
      errors = []
      entries = []
      pairs.each do |name, env, override|
        cfg = @catalog.config(name, env)
        cfg = cfg.merge('image_tag' => override) if override
        label = "#{name}/#{env}"
        if cfg['enabled'] == false
          notices << "#{label} is disabled (enabled: false); skipped."
          next
        end
        unless cfg['provider'] == 'ovh'
          notices << "#{label} uses provider #{cfg['provider'].inspect}; this pipeline only deploys ovh. Skipped."
          next
        end
        problems = validate(cfg)
        if problems.empty?
          entries << entry(cfg)
        else
          errors.concat(problems.map { |p| "#{label}: #{p}" })
        end
      end
      Result.new(entries: entries, notices: notices, errors: errors)
    end

    def validate(cfg)
      problems = []
      problems << "project name must match #{NAME.source}" unless cfg['name'].match?(NAME)
      tag_problem = PatchworkDeploy.tag_error(cfg['image_tag'], cfg['environment'])
      problems << tag_problem if tag_problem
      %w(runner).each { |k| problems << "#{k} is required" if cfg[k].to_s.empty? }
      %w(registry harbor_project pull_username).each do |k|
        problems << "image.#{k} is required" if cfg.dig('image', k).to_s.empty?
      end
      %w(deploy_dir credential_dir).each do |k|
        value = cfg.dig('host', k).to_s
        problems << "host.#{k} must be an absolute path" unless value.start_with?('/')
      end
      release_env_pairs(cfg).each do |key, value|
        problems << "#{key} must not contain '$', quotes or newlines (got #{value.inspect})" if value.to_s.match?(/[$\n"'\\]/)
      end
      problems
    end

    # KEY=VALUE pairs written to the release's .env on the host. docker compose
    # reads them to fill in deploy/compose/mastodon.yml.
    def release_env_pairs(cfg)
      image = cfg['image'] || {}
      base = "#{image['registry']}/#{image['harbor_project']}"
      res = cfg['resources'] || {}
      compose_files = ['mastodon.yml']
      compose_files << 'override.yml' unless cfg['override_file'].to_s.empty?
      {
        'COMPOSE_FILE' => compose_files.join(':'),
        'DEPLOY_PROJECT' => cfg['name'],
        'DEPLOY_ENVIRONMENT' => cfg['environment'],
        'RELEASE_TAG' => cfg['image_tag'],
        'WEB_IMAGE' => "#{base}/web:#{cfg['image_tag']}",
        'STREAMING_IMAGE' => "#{base}/streaming:#{cfg['image_tag']}",
        'CREDENTIAL_DIR' => cfg.dig('host', 'credential_dir'),
        'FIREBASE_CONTAINER_PATH' => cfg.dig('runtime', 'firebase_container_path'),
        'STREAMING_DB_SSLMODE' => cfg.dig('runtime', 'streaming_db_sslmode'),
        'WEB_CPUS' => res.dig('web', 'cpus'),
        'WEB_MEMORY' => res.dig('web', 'memory'),
        'SIDEKIQ_CPUS' => res.dig('sidekiq', 'cpus'),
        'SIDEKIQ_MEMORY' => res.dig('sidekiq', 'memory'),
        'SIDEKIQ_REPLICAS' => res.dig('sidekiq', 'replicas'),
        'STREAMING_CPUS' => res.dig('streaming', 'cpus'),
        'STREAMING_MEMORY' => res.dig('streaming', 'memory'),
      }.reject { |_k, v| v.nil? || v.to_s.empty? }
    end

    def entry(cfg)
      header = "# Generated by deploy/bin/plan-deploy for #{cfg['name']}/#{cfg['environment']}. Do not edit on the host; change deploy/projects instead."
      env_lines = release_env_pairs(cfg).map { |k, v| "#{k}=#{v}" }
      {
        'project' => cfg['name'],
        'environment' => cfg['environment'],
        'image_tag' => cfg['image_tag'],
        'runner' => cfg['runner'],
        'registry' => cfg.dig('image', 'registry'),
        'pull_username' => cfg.dig('image', 'pull_username'),
        'deploy_dir' => cfg.dig('host', 'deploy_dir'),
        'public_url' => cfg['public_url'].to_s,
        'override_file' => cfg['override_file'],
        'release_env' => ([header] + env_lines).join("\n"),
      }
    end
  end
end
