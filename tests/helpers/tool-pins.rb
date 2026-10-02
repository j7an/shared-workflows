require 'yaml'

PIN_LINE = ->(key) { /^\s+#{Regexp.escape(key)}: "\d+\.\d+\.\d+"\s*$/ }

def each_with_block
  Dir['.github/workflows/*.yml', 'actions/*/action.yml'].sort.each do |file|
    document = YAML.safe_load(File.read(file))
    (document['jobs'] || {}).each_value do |job|
      yield file, job['uses'], job.fetch('with', {}) if job['uses']
      (job['steps'] || []).each do |step|
        yield file, step['uses'], step.fetch('with', {})
      end
    end
    (document.dig('runs', 'steps') || []).each do |step|
      yield file, step['uses'], step.fetch('with', {})
    end
  end
end

def matrix_entries
  YAML.safe_load(File.read('.github/workflows/tool-pin-bump.yml')).dig('jobs', 'bump', 'strategy', 'matrix', 'include')
end
